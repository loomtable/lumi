import AudioToolbox
import CoreAudio
import Darwin
import Dispatch

/// The few Core Audio HAL calls the mic needs.
enum AudioHAL {
    /// Whether another process is playing audio right now (a video, music, a call). Lumi's own
    /// replies and sounds don't count. Reads Core Audio's process objects (macOS 14+). If that list can't
    /// be read there's no telling whose audio is playing, so it answers no: a plain capture keeps the first
    /// word, where guessing yes would let our own reply switch voice processing on.
    static func otherProcessIsPlayingOutput() -> Bool {
        OtherAudio.usesVoiceIsolation(players: otherOutputPlayers(), route: defaultOutputRoute())
    }

    /// Where the default output plays: whether it can bleed into the mic. Built-in speakers and
    /// external outputs can; headphones (the built-in jack's data source) and Bluetooth can't
    /// (almost always a headset); muted or at zero volume nothing is heard.
    static func defaultOutputRoute() -> OtherAudio.Route {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return .speakers } // unknown: as before
        if outputValue(device, kAudioDevicePropertyMute, UInt32(0)) == 1 { return .silent }
        if let volume = outputValue(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float32(-1)), volume == 0 {
            return .silent
        }
        let transport = value(device, kAudioDevicePropertyTransportType, UInt32(0))
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return .headphones }
        if transport == kAudioDeviceTransportTypeBuiltIn, outputValue(device, kAudioDevicePropertyDataSource, UInt32(0)) == headphonesSource {
            return .headphones
        }
        return .speakers
    }

    /// The built-in output's headphone-jack data source ('hdpn').
    private static let headphonesSource: UInt32 = 0x6864_706E

    private static func outputValue<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                        _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : nil
    }

    /// The bundle IDs of the other processes running output now ("unknown" for one without an
    /// ID). Empty when the list can't be read.
    static func otherOutputPlayers() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        let me = getpid()
        return processes.filter { process in
            value(process, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1
                && value(process, kAudioProcessPropertyPID, pid_t(0)) != me
        }.map { bundleID($0) ?? "unknown" }
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &id) == noErr, let id else { return nil }
        let value = id.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }

    private static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? result : nil
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var address = defaultInputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// Whether any client is running the default input device (what lights the mic indicator).
    static func isDefaultInputRunning() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(defaultInputDevice(), &address, 0, nil, &size, &running)
        return running != 0
    }

    /// Wraps `handler` as a HAL listener block. Built here, outside any actor, because the HAL calls it on
    /// `queue`; a closure written inside an actor would inherit its isolation and trap.
    static func listenerBlock(_ handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in handler() }
    }

    @discardableResult
    static func addDefaultInputListener(_ block: @escaping AudioObjectPropertyListenerBlock,
                                        queue: DispatchQueue) -> OSStatus {
        var address = defaultInputAddress
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    /// Needs the same block and queue that were added.
    static func removeDefaultInputListener(_ block: @escaping AudioObjectPropertyListenerBlock, queue: DispatchQueue) {
        var address = defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }
}
