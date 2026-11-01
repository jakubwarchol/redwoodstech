import AppKit

// MARK: - Keyboard cleaning mode

/// Swallows every keyboard event (keys, modifiers, media/brightness keys) so the keyboard can be wiped.
/// Mouse and trackpad keep working; clicking the menu bar tree turns it off.
/// Same technique as Cleeb and keyboard-cleaner (both MIT): an HID-level event tap that returns nil.
final class KeyboardBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var safetyTimer: Timer?

    /// Unlocks on its own after this long, in case the mouse is unavailable.
    static let maxDuration: TimeInterval = 5 * 60
    var onChange: (() -> Void)?

    var isBlocking: Bool { tap != nil }

    // NX_SYSDEFINED carries media, volume and brightness keys (subtype 8, NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    // Other subtypes (e.g. 7, extra mouse buttons) are let through.
    private static let systemDefined: UInt32 = 14
    private static let auxControlButtons: Int16 = 8

    init() {
        // Never leave the keyboard dead on the lock screen or after sleep, where the password is typed.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    /// Fails until the app has Accessibility access.
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue,
                               CGEventType.flagsChanged.rawValue, Self.systemDefined]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let blocker = Unmanaged<KeyboardBlocker>.fromOpaque(userInfo!).takeUnretainedValue()
                return blocker.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        safetyTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
            self?.stop()
        }
        log("keyboard blocked for cleaning")
        onChange?()
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        log("keyboard unblocked")
        onChange?()
    }

    /// Returns true to drop the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type.rawValue == Self.systemDefined {
            return NSEvent(cgEvent: event)?.subtype.rawValue == Self.auxControlButtons
        }
        return true
    }
}
