import AppKit

// External mice only: pointer acceleration off and scroll wheel reversed, so the trackpad keeps
// natural scrolling. Approach borrowed from LinearMouse (formerly the separate Mousefix app).

// MARK: - Mouse devices (acceleration)

struct PointingDevice {
    let service: IOHIDServiceClient
    let name: String
    let isExternalMouse: Bool
}

final class DeviceWatcher {
    private var client: IOHIDEventSystemClient?
    /// Keyed by service registry ID, which is also the sender ID of the events the device produces.
    private(set) var devices: [UInt64: PointingDevice] = [:]
    var onChange: (() -> Void)?

    var externalMice: [PointingDevice] { devices.values.filter(\.isExternalMouse) }

    func start() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            log("could not create HID event system client")
            return
        }
        self.client = client

        let matches = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ] as CFArray
        IOHIDEventSystemClientSetMatchingMultiple(client, matches)
        IOHIDEventSystemClientRegisterDeviceMatchingBlock(client, { [weak self] _, _, service in
            guard let service else { return }
            DispatchQueue.main.async { self?.add(service) }
        }, nil, nil)
        IOHIDEventSystemClientScheduleWithDispatchQueue(client, .main)

        for service in IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? [] {
            add(service)
        }
    }

    /// The system can reset a device's pointer settings after wake, so re-apply them.
    func reapplyAll() {
        for mouse in externalMice { disableAcceleration(mouse) }
    }

    private func add(_ service: IOHIDServiceClient) {
        guard let id = Self.registryID(of: service), devices[id] == nil else { return }

        let builtIn = (IOHIDServiceClientCopyProperty(service, kIOHIDBuiltInKey as CFString) as? Bool) ?? false
        let trackpad = IOHIDServiceClientConformsTo(
            service, UInt32(kHIDPage_Digitizer), UInt32(kHIDUsage_Dig_TouchPad)) != 0
        let name = IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "Unknown device"
        let device = PointingDevice(service: service, name: name, isExternalMouse: !builtIn && !trackpad)
        devices[id] = device
        log("added \(name) (id \(id), built-in \(builtIn), trackpad \(trackpad))")

        IOHIDServiceClientRegisterRemovalBlock(service, { [weak self] _, _, _ in
            DispatchQueue.main.async {
                self?.devices[id] = nil
                log("removed \(name)")
                self?.onChange?()
            }
        }, nil, nil)

        if device.isExternalMouse {
            // The system applies its own saved preferences to a freshly connected device shortly
            // after it appears, which can overwrite an immediate write. Apply again a bit later.
            disableAcceleration(device)
            for delay in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard self?.devices[id] != nil else { return }
                    self?.disableAcceleration(device)
                }
            }
        }
        onChange?()
    }

    private func disableAcceleration(_ device: PointingDevice) {
        let linearKey = "HIDUseLinearScalingMouseAcceleration" as CFString
        if IOHIDServiceClientCopyProperty(device.service, linearKey) != nil {
            // macOS 14+: the same switch as "Pointer acceleration" in System Settings → Mouse.
            IOHIDServiceClientSetProperty(device.service, linearKey, 1 as CFNumber)
            let now = IOHIDServiceClientCopyProperty(device.service, linearKey) as? Int
            log("\(device.name): \(linearKey) = \(now.map(String.init) ?? "nil")")
        } else {
            // Older systems: an acceleration of -1 (as IOFixed) disables it.
            let typeKey = IOHIDServiceClientCopyProperty(device.service, "HIDPointerAccelerationType" as CFString)
                as? String ?? "HIDMouseAcceleration"
            IOHIDServiceClientSetProperty(device.service, typeKey as CFString, -65536 as CFNumber)
            log("\(device.name): \(typeKey) = -1")
        }
    }

    private static func registryID(of service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }
}

// MARK: - Scroll wheel reversal

final class ScrollReverser {
    private var tap: CFMachPort?
    private let shouldReverse: (_ senderID: UInt64, _ continuous: Bool) -> Bool

    var isRunning: Bool { tap != nil }

    init(shouldReverse: @escaping (UInt64, Bool) -> Bool) {
        self.shouldReverse = shouldReverse
    }

    /// Fails until the app has Accessibility access.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let reverser = Unmanaged<ScrollReverser>.fromOpaque(userInfo!).takeUnretainedValue()
                reverser.handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        log("scroll event tap installed")
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .scrollWheel else { return }

        let hidEvent = CGEventCopyIOHIDEvent(event)
        let senderID = hidEvent.map { IOHIDEventGetSenderID($0) } ?? 0
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard shouldReverse(senderID, continuous) else { return }

        // Read everything before writing: setting one delta field can update the others.
        let axes: [(CGEventField, CGEventField, CGEventField, UInt32)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1, 0x60001),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2, 0x60000),
        ]  // last value: kIOHIDEventFieldScrollY / ScrollX
        let values = axes.map { line, fixed, point, hidField in
            (event.getIntegerValueField(line), event.getDoubleValueField(fixed), event.getDoubleValueField(point),
             hidEvent.map { IOHIDEventGetFloatValue($0, hidField) } ?? 0)
        }
        for ((line, fixed, point, hidField), (lineValue, fixedValue, pointValue, hidValue)) in zip(axes, values) {
            event.setIntegerValueField(line, value: -lineValue)
            event.setDoubleValueField(fixed, value: -fixedValue)
            event.setDoubleValueField(point, value: -pointValue)
            if let hidEvent { IOHIDEventSetFloatValue(hidEvent, hidField, -hidValue) }
        }
    }
}

