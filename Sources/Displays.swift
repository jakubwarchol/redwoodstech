import AppKit
import ColorSync

// Display layout presets. A "setup" is the set of connected displays plus whether an external
// mouse is connected; each setup can have one saved layout (positions, main display, modes),
// which is re-applied whenever the Mac switches into that setup.

struct DisplayState: Codable, Equatable {
    let uuid: String
    let name: String
    let x: Int
    let y: Int
    let isMain: Bool
    // Mode: size in points, size in pixels (differs for HiDPI), refresh rate.
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    func sameLayout(as other: DisplayState) -> Bool {
        uuid == other.uuid && x == other.x && y == other.y && isMain == other.isMain
            && width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && abs(refreshRate - other.refreshRate) < 0.5
    }
}

struct Setup: Hashable {
    let displayUUIDs: [String]  // sorted
    let mouseConnected: Bool

    var key: String { displayUUIDs.joined(separator: ",") + (mouseConnected ? "|mouse" : "|no-mouse") }
}

struct Preset: Codable {
    let key: String
    let mouseConnected: Bool
    let displays: [DisplayState]
    let savedAt: Date

    var title: String {
        let names = displays.sorted { $0.x < $1.x }.map(\.name).joined(separator: " + ")
        return "\(names) · \(mouseConnected ? "mouse" : "no mouse")"
    }
}

enum Displays {
    static func activeIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Stable across reconnects and reboots, unlike CGDirectDisplayID.
    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func name(of id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if CGDisplayIsBuiltin(id) != 0 { return "Built-in" }
        return screen?.localizedName ?? "Display \(id)"
    }

    static func current() -> [DisplayState] {
        activeIDs().compactMap { id in
            guard let uuid = uuid(of: id), let mode = CGDisplayCopyDisplayMode(id) else { return nil }
            let bounds = CGDisplayBounds(id)
            return DisplayState(
                uuid: uuid, name: name(of: id), x: Int(bounds.origin.x), y: Int(bounds.origin.y),
                isMain: CGDisplayIsMain(id) != 0,
                width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                refreshRate: mode.refreshRate)
        }
    }

    /// Applies a saved layout. Returns false if a display is missing or the change was rejected.
    static func apply(_ preset: Preset) -> Bool {
        var idsByUUID: [String: CGDirectDisplayID] = [:]
        for id in activeIDs() { if let uuid = uuid(of: id) { idsByUUID[uuid] = id } }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for saved in preset.displays {
            guard let id = idsByUUID[saved.uuid] else {
                CGCancelDisplayConfiguration(config)
                return false
            }
            if let current = CGDisplayCopyDisplayMode(id), !matches(current, saved),
               let mode = findMode(for: id, matching: saved) {
                CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
            }
            // The display placed at (0, 0) becomes the main display.
            CGConfigureDisplayOrigin(config, id, Int32(saved.x), Int32(saved.y))
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success { log("display configuration failed: \(result.rawValue)") }
        return result == .success
    }

    private static func matches(_ mode: CGDisplayMode, _ saved: DisplayState) -> Bool {
        mode.width == saved.width && mode.height == saved.height
            && mode.pixelWidth == saved.pixelWidth && mode.pixelHeight == saved.pixelHeight
            && abs(mode.refreshRate - saved.refreshRate) < 0.5
    }

    private static func findMode(for id: CGDirectDisplayID, matching saved: DisplayState) -> CGDisplayMode? {
        // Without this option the list leaves out the HiDPI ("looks like") modes.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return modes.first { matches($0, saved) }
    }
}

/// Remembers one layout per setup and switches to it when the setup changes.
final class LayoutSwitcher {
    private let defaultsKey = "displayPresets"
    private let autoSwitchKey = "autoSwitchLayouts"
    private(set) var presets: [String: Preset] = [:]
    private var lastSetupKey: String?
    private var pending: DispatchWorkItem?
    private let mouseConnected: () -> Bool

    var autoSwitch: Bool {
        get { UserDefaults.standard.object(forKey: autoSwitchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoSwitchKey) }
    }

    init(mouseConnected: @escaping () -> Bool) {
        self.mouseConnected = mouseConnected
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: Preset].self, from: data) {
            presets = saved
        }
    }

    func start() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
            let switcher = Unmanaged<LayoutSwitcher>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { switcher.setupMayHaveChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())
        setupMayHaveChanged()
    }

    var currentSetup: Setup {
        Setup(displayUUIDs: Displays.activeIDs().compactMap(Displays.uuid(of:)).sorted(),
              mouseConnected: mouseConnected())
    }

    var presetForCurrentSetup: Preset? { presets[currentSetup.key] }

    /// Called for mouse and display changes. Only a change of setup triggers a switch, so rearranging
    /// displays in System Settings within the same setup is left alone (and can then be saved).
    func setupMayHaveChanged() {
        // Display changes arrive in bursts, and a mouse can blip during reconnects: wait for things to settle.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func evaluate() {
        let key = currentSetup.key
        guard key != lastSetupKey else { return }
        lastSetupKey = key
        log("setup is now \(key)")
        guard autoSwitch, let preset = presets[key] else { return }
        applyIfNeeded(preset)
        // macOS restores its own remembered arrangement shortly after a display connects,
        // which can undo ours. Check once more after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.currentSetup.key == key else { return }
            self.applyIfNeeded(preset)
        }
    }

    func applyIfNeeded(_ preset: Preset) {
        let current = Displays.current()
        let alreadyApplied = preset.displays.allSatisfy { saved in
            current.contains { $0.sameLayout(as: saved) }
        }
        guard !alreadyApplied else { return }
        log("applying layout \(preset.title)")
        _ = Displays.apply(preset)
    }

    func saveCurrentLayout() {
        let setup = currentSetup
        presets[setup.key] = Preset(key: setup.key, mouseConnected: setup.mouseConnected,
                                    displays: Displays.current(), savedAt: Date())
        lastSetupKey = setup.key
        persist()
    }

    func deletePreset(key: String) {
        presets[key] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
