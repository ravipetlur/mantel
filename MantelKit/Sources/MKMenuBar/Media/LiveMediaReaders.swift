import CoreAudio
import CoreMediaIO
import Foundation
import MKCore

/// The readers of the real mic and camera, made by the app. A test is given readers of its own.
///
/// **Neither asks for permission.** A mic or camera is only asked for by opening it (a capture session, an audio unit's input, a device
/// start), and these never do. No capture framework is used, and no microphone or camera is touched, so macOS has nothing to ask the
/// person about and shows no indicator of Mantel's own.
/// - **The mic** is read through CoreAudio's process objects: for each app that uses audio, whether it has input running.
/// - **The camera** is read through CoreMediaIO's devices: whether *anything* is running each one (`...IsRunningSomewhere`, a property the
///   system keeps for every device and tells any app). A camera only captures, so the device as a whole is the right thing to ask.
public enum LiveMediaReaders {
    public static func all() -> [any MediaUseReading] {
        [DeviceWatch(kind: .mic, system: InputProcesses(objects: CoreAudioProcessObjects(), ownPID: ProcessInfo.processInfo.processIdentifier)),
         DeviceWatch(kind: .camera, system: CoreMediaCameras())]
    }
}

/// What is shown when a device's name can't be read.
private let unnamedDevice = "unnamed device"

// MARK: The mic

/// The process objects of CoreAudio (macOS 14.2 and later): one for each process that uses audio, each saying its PID, its bundle ID and
/// whether it has input running (`kAudioProcessPropertyIsRunningInput`).
///
/// The device is not asked: `kAudioDevicePropertyDeviceIsRunningSomewhere` is about the device as a whole, and a headset or a display with
/// speakers and a mic is one device, so sound played through it would read as the mic in use. The process's own flag is about input alone.
struct CoreAudioProcessObjects: AudioProcessObjects {
    typealias Process = AudioObjectID

    private let queue = DispatchQueue(label: "mantel.media.audio")

    /// The listener, kept as the one block that is added and later taken away: the system finds it by identity.
    private struct Block: @unchecked Sendable {
        let run: AudioObjectPropertyListenerBlock
        init(_ run: @escaping AudioObjectPropertyListenerBlock) { self.run = run }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func processes() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func pid(of process: AudioObjectID) -> pid_t? {
        var address = Self.address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    func bundleID(of process: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0) }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = Self.address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        observe(Self.system, Self.address(kAudioHardwarePropertyProcessObjectList), handler)
    }

    func observeRunningInput(of process: AudioObjectID, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        observe(process, Self.address(kAudioProcessPropertyIsRunningInput), handler)
    }

    private func observe(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress,
                         _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        var address = property
        let block = Block { _, _ in handler() }
        let queue = queue
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block.run)
        guard status == noErr else {
            Log.warning("media", "the mic couldn't be watched (error \(status))")
            return DeviceObservation(cancel: {})
        }
        return DeviceObservation {
            var address = property
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block.run)
        }
    }
}

// MARK: The camera

/// The video devices, through CoreMediaIO: every device the system lists.
struct CoreMediaCameras: DeviceSystem {
    typealias Device = CMIOObjectID

    private let queue = DispatchQueue(label: "mantel.media.camera")

    /// The listener, kept as the one block that is added and later taken away: the system finds it by identity.
    private struct Block: @unchecked Sendable {
        let run: CMIOObjectPropertyListenerBlock
        init(_ run: @escaping CMIOObjectPropertyListenerBlock) { self.run = run }
    }
    private static let system = CMIOObjectID(kCMIOObjectSystemObject)

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    func devices() -> [CMIOObjectID] {
        var address = Self.address(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(Self.system, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    func name(of device: CMIOObjectID) -> String {
        var address = Self.address(kCMIOObjectPropertyName)
        var name: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &name) { CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, $0) }
        guard status == noErr, let name else { return unnamedDevice }
        return name.takeRetainedValue() as String
    }

    func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running) == noErr && running != 0
    }

    func observeList(_ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        observe(Self.system, Self.address(kCMIOHardwarePropertyDevices), handler)
    }

    func observeRunning(of device: CMIOObjectID, _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        observe(device, Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere), handler)
    }

    private func observe(_ object: CMIOObjectID, _ property: CMIOObjectPropertyAddress,
                         _ handler: @escaping @Sendable () -> Void) -> DeviceObservation {
        var address = property
        let block = Block { _, _ in handler() }
        let queue = queue
        let status = CMIOObjectAddPropertyListenerBlock(object, &address, queue, block.run)
        guard status == noErr else {
            Log.warning("media", "a camera couldn't be watched (error \(status))")
            return DeviceObservation(cancel: {})
        }
        return DeviceObservation {
            var address = property
            CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block.run)
        }
    }
}
