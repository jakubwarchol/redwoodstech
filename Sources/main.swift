import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import ServiceManagement

// RedwoodsTech: one menu bar pine tree that
//  - keeps the Mac awake (left-click; filled tree = awake),
//  - fixes external mice (acceleration off, reversed wheel; see Mouse.swift),
//  - switches display layouts per setup of monitors + mouse (see Displays.swift),
//  - locks the keyboard for cleaning (see Keyboard.swift).

func log(_ message: String) { NSLog("RedwoodsTech: \(message)") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var assertionID: IOPMAssertionID = 0
    private var isAwake = false

    private let watcher = DeviceWatcher()
    private lazy var reverser = ScrollReverser { [watcher] senderID, continuous in
        if let device = watcher.devices[senderID] { return device.isExternalMouse }
        // Unknown sender: a classic notched wheel sends line-based (non-continuous) events, a trackpad doesn't.
        return !continuous
    }
    private var tapRetryTimer: Timer?
    private lazy var layouts = LayoutSwitcher { [watcher] in !watcher.externalMice.isEmpty }
    private let keyboard = KeyboardBlocker()

    private lazy var sleepyIcon = templateImage("menubar-sleeping")
    private lazy var awakeIcon = templateImage("menubar-awake")
    private lazy var cleaningIcon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard locked")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        watcher.onChange = { [weak self] in
            self?.updateStatus()
            self?.layouts.setupMayHaveChanged()
        }
        watcher.start()
        keyboard.onChange = { [weak self] in self?.updateStatus() }
        startScrollReversal()
        layouts.start()
        registerLoginItemOnFirstRun()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.watcher.reapplyAll() }
        }
        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        setAwake(false)
        keyboard.stop()
    }

    @objc private func statusItemClicked() {
        // While cleaning, any click on the icon gives the keyboard back.
        if keyboard.isBlocking {
            keyboard.stop()
            return
        }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            setAwake(!isAwake)
        }
    }

    // MARK: Awake

    private func setAwake(_ awake: Bool) {
        if awake, !isAwake {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "RedwoodsTech: keeping the Mac awake" as CFString,
                &assertionID)
            isAwake = result == kIOReturnSuccess
        } else if !awake, isAwake {
            IOPMAssertionRelease(assertionID)
            isAwake = false
        }
        updateStatus()
    }

    private func updateStatus() {
        if keyboard.isBlocking {
            statusItem.button?.image = cleaningIcon
            statusItem.button?.toolTip = "Keyboard locked for cleaning (click to unlock)"
            return
        }
        statusItem.button?.image = isAwake ? awakeIcon : sleepyIcon
        var lines = [isAwake ? "Keeping your Mac awake (click to stop)" : "Normal sleep (click to keep awake)"]
        let mice = watcher.externalMice.map(\.name)
        lines.append(mice.isEmpty ? "No mouse connected" : "Mouse: \(mice.joined(separator: ", "))")
        if !reverser.isRunning { lines.append("Needs Accessibility access") }
        statusItem.button?.toolTip = lines.joined(separator: "\n")
    }

    // MARK: Mouse

    private func startScrollReversal() {
        if reverser.start() { return }
        // Ask once for Accessibility access, then keep trying until it's granted (no relaunch needed).
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.reverser.start() == true {
                timer.invalidate()
                self?.updateStatus()
            }
        }
    }

    // MARK: Menu (right-click)

    private func showMenu() {
        let menu = NSMenu()
        add(menu, isAwake ? "Stop Keeping Awake" : "Keep Awake", #selector(toggleAwake))
        add(menu, "Lock Keyboard for Cleaning", #selector(startCleaning))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Mouse"))
        let mice = watcher.externalMice.map(\.name).sorted()
        if mice.isEmpty {
            menu.addItem(withTitle: "No mouse connected", action: nil, keyEquivalent: "")
        } else {
            for name in mice {
                menu.addItem(withTitle: name, action: nil, keyEquivalent: "").image =
                    NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
            }
            menu.addItem(withTitle: "Acceleration off · scroll reversed", action: nil, keyEquivalent: "")
        }
        if !reverser.isRunning {
            add(menu, "Grant Accessibility Access…", #selector(openAccessibilitySettings))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Display Layouts"))
        let current = layouts.presetForCurrentSetup
        add(menu, current == nil ? "Save Layout for This Setup" : "Update Layout for This Setup",
            #selector(saveLayout))
        if current != nil {
            add(menu, "Apply Saved Layout", #selector(applyLayout))
        }
        add(menu, "Switch Layouts Automatically", #selector(toggleAutoSwitch)).state =
            layouts.autoSwitch ? .on : .off
        if !layouts.presets.isEmpty {
            let saved = NSMenu()
            for preset in layouts.presets.values.sorted(by: { $0.title < $1.title }) {
                let item = saved.addItem(withTitle: preset.title, action: nil, keyEquivalent: "")
                item.state = preset.key == current?.key ? .on : .off
                let actions = NSMenu()
                let delete = add(actions, "Delete", #selector(deleteLayout(_:)))
                delete.representedObject = preset.key
                item.submenu = actions
            }
            menu.addItem(withTitle: "Saved Layouts", action: nil, keyEquivalent: "").submenu = saved
        }

        menu.addItem(.separator())
        add(menu, "Open at Login", #selector(toggleLoginItem)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit RedwoodsTech", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleAwake() { setAwake(!isAwake) }

    @objc private func startCleaning() {
        if !keyboard.start() { openAccessibilitySettings() }
    }

    @objc private func saveLayout() { layouts.saveCurrentLayout() }

    @objc private func applyLayout() {
        if let preset = layouts.presetForCurrentSetup { layouts.applyIfNeeded(preset) }
    }

    @objc private func toggleAutoSwitch() { layouts.autoSwitch.toggle() }

    @objc private func deleteLayout(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { layouts.deletePreset(key: key) }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Login item

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("login item change failed: \(error)")
        }
    }

    private func registerLoginItemOnFirstRun() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            log("login item registration failed: \(error)")
        }
    }

    private func templateImage(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
