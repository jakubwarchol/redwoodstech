import AppKit
import Carbon.HIToolbox
import CoreAudio

// MARK: - Duck other apps

/// Turns every app except the frontmost one (e.g. WoW, for quest dialogue) down to `level`.
/// macOS has no per-app volume, so this uses a Core Audio process tap (macOS 14.2+), the technique from
/// Apple's "Capturing system audio with Core Audio taps" sample and AudioCap (insidegui, BSD-2):
/// a global tap that excludes the kept app mutes everything else, and an aggregate device re-plays
/// that tapped mix to the current output at reduced gain. Destroying the tap restores the original levels.
final class AudioDucker {
    static let level: Float = 0.1
    var onChange: (() -> Void)?

    private(set) var keptAppName: String?
    var isDucking: Bool { engine != nil }
    /// Set when the last attempt failed, usually because System Audio Recording access was denied.
    private(set) var lastError: String?

    private var engine: DuckEngine?
    private var excluded: [AudioObjectID] = []
    private var keptAppPath: String?

    init() {
        // Ducked audio is pinned to the output device it started on; follow headphone/AirPods switches.
        var address = AudioObjectPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.isDucking else { return }
            log("output device changed, rebuilding duck")
            self.engine = nil
            self.startEngine()
        }
    }

    func toggle() { isDucking ? stop() : start() }

    func start() {
        guard !isDucking else { return }
        let front = NSWorkspace.shared.frontmostApplication
        keptAppName = front?.localizedName
        keptAppPath = front?.bundleURL?.path
        startEngine()
    }

    func stop() {
        guard isDucking else { return }
        engine = nil
        log("duck off")
        onChange?()
    }

    private func startEngine() {
        excluded = processesToKeep()
        do {
            engine = try DuckEngine(excluding: excluded, gain: Self.level)
            lastError = nil
            log("ducking everything except \(keptAppName ?? "?") (\(excluded.count) audio processes kept)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if let peak = self?.engine?.peak.pointee { log("tapped audio peak after 3 s: \(peak)") }
            }
        } catch {
            engine = nil
            lastError = "\(error)"
            log("duck failed: \(error)")
        }
        onChange?()
    }

    /// Audio process objects to leave alone: everything running from inside the kept app's bundle
    /// (WoW's voice chat runs as a separate helper app inside it) plus ourselves, so the replayed
    /// audio isn't tapped again.
    private func processesToKeep() -> [AudioObjectID] {
        let ownPID = getpid()
        let prefix = keptAppPath.map { $0 + "/" }
        return AudioObjectID(kAudioObjectSystemObject).array(kAudioHardwarePropertyProcessObjectList).filter { process in
            guard let pid: pid_t = process.value(kAudioProcessPropertyPID) else { return false }
            if pid == ownPID { return true }
            guard let prefix, let path = executablePath(pid) else { return false }
            return path.hasPrefix(prefix)
        }
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// One tap + aggregate device + IOProc. Everything is torn down in deinit, which unmutes the tapped apps.
final class DuckEngine {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Loudest tapped sample so far, written by the IOProc; all zeros usually means no System Audio Recording access.
    let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ step: String, _ status: OSStatus) { description = "\(step) failed (\(status))" }
    }

    init(excluding processes: [AudioObjectID], gain: Float) throws {
        peak.initialize(to: 0)
        do { try build(processes, gain) } catch { teardown(); throw error }
    }

    deinit {
        teardown()
        peak.deallocate()
    }

    private func build(_ processes: [AudioObjectID], _ gain: Float) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        description.name = "RedwoodsTech duck"
        description.isPrivate = true
        // Muted only while we're actually reading the tap, so a stalled IOProc can't leave apps silent.
        description.muteBehavior = .mutedWhenTapped
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure("creating the audio tap (System Audio Recording access?)", status) }

        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let output: AudioObjectID = system.value(kAudioHardwarePropertyDefaultOutputDevice),
              let outputUID = output.string(kAudioDevicePropertyDeviceUID),
              let tapUID = tapID.string(kAudioTapPropertyUID)
        else { throw Failure("reading the output device", -1) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "RedwoodsTech Duck",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw Failure("creating the aggregate device", status) }

        // The aggregate's input is the output device's own inputs (a headset mic, say) followed by the tap.
        // Skip the device's inputs so only the tapped apps are replayed.
        let skip = output.streamCount(scope: kAudioObjectPropertyScopeInput)
        let peak = peak
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                        into: UnsafeMutableAudioBufferListPointer(output), skip: skip, gain: gain, peak: peak)
        }
        guard status == noErr else { throw Failure("creating the IOProc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw Failure("starting the aggregate device", status) }
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Realtime thread: copies the tapped float32 stereo mix (interleaved or not) to every output channel,
    /// left/right alternating, scaled by gain. No allocation or locks.
    private static func render(_ input: UnsafeMutableAudioBufferListPointer,
                               into output: UnsafeMutableAudioBufferListPointer, skip: Int, gain: Float,
                               peak: UnsafeMutablePointer<Float>) {
        var inChannels = 0
        for i in skip..<max(skip, input.count) { inChannels += Int(input[i].mNumberChannels) }

        var outChannel = 0
        for buffer in output {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outStride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(outStride, 1))
            for c in 0..<outStride {
                defer { outChannel += 1 }
                // Find source channel (outChannel % inChannels) among the tap's buffers.
                var source: UnsafePointer<Float>?
                var inStride = 1
                var inFrames = 0
                if inChannels > 0 {
                    var wanted = outChannel % inChannels
                    for i in skip..<input.count {
                        let channels = Int(input[i].mNumberChannels)
                        if wanted < channels, let data = input[i].mData?.assumingMemoryBound(to: Float.self) {
                            source = UnsafePointer(data + wanted)
                            inStride = channels
                            inFrames = Int(input[i].mDataByteSize) / (MemoryLayout<Float>.size * channels)
                            break
                        }
                        wanted -= channels
                    }
                }
                for f in 0..<frames {
                    let sample = (source != nil && f < inFrames) ? source![f * inStride] : 0
                    if abs(sample) > peak.pointee { peak.pointee = abs(sample) }
                    out[f * outStride + c] = sample * gain
                }
            }
        }
    }
}

// MARK: - Global hotkey

/// A system-wide hotkey through Carbon's RegisterEventHotKey: no Accessibility needed, works in
/// fullscreen games, and the keystroke is swallowed so the frontmost app never sees it.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5257_5448), id: 1) // 'RWTH'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            log("hotkey registration failed (\(status))")
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Core Audio property helpers

private extension AudioObjectPropertyAddress {
    init(selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        self.init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

private extension AudioObjectID {
    func value<T>(_ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(selector: selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(selector: selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func array(_ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(selector: selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        array(kAudioDevicePropertyStreams, scope: scope).count
    }
}
