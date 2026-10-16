import Foundation
import CoreAudio

/// Device-scoped HAL volume, independent of SoundMix's DSP gain and playback state.
public enum DeviceVolume {
    public struct Backend {
        var read: (AudioDeviceID, AudioObjectPropertyScope, UInt32) -> Float?
        var writable: (AudioDeviceID, AudioObjectPropertyScope, UInt32) -> Bool
        var write: (AudioDeviceID, AudioObjectPropertyScope, UInt32, Float) -> OSStatus
    }

    public struct State {
        public var value: Double?
        public var writable: Bool
        public var channelControls: Int
    }

    public enum VolumeError: LocalizedError {
        case unavailable
        case failed(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "This device does not expose a writable macOS volume control."
            case .failed(let status): return "Device volume could not be changed (Core Audio status \(status))."
            }
        }
    }

    private static func address(_ scope: AudioObjectPropertyScope, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: scope, mElement: element)
    }

    static let hal = Backend(
        read: { device, scope, element in
            var property = address(scope, element)
            guard AudioObjectHasProperty(device, &property) else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
                  value.isFinite else { return nil }
            return min(1, max(0, value))
        },
        writable: { device, scope, element in
            var property = address(scope, element)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &property)
                && AudioObjectIsPropertySettable(device, &property, &settable) == noErr
                && settable.boolValue
        },
        write: { device, scope, element, scalar in
            var property = address(scope, element)
            var value = scalar
            return AudioObjectSetPropertyData(device, &property, 0, nil,
                                              UInt32(MemoryLayout<Float32>.size), &value)
        })

    private static func controls(device: AudioDeviceID, isInput: Bool, channels: Int,
                                 backend: Backend) -> [(element: UInt32, value: Float, writable: Bool)] {
        let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let master = backend.read(device, scope, kAudioObjectPropertyElementMain)
        if let master, backend.writable(device, scope, kAudioObjectPropertyElementMain) {
            return [(kAudioObjectPropertyElementMain, master, true)]
        }
        let channelControls = (0..<max(0, channels)).compactMap { index -> (UInt32, Float, Bool)? in
            let element = UInt32(index + 1)
            guard let value = backend.read(device, scope, element) else { return nil }
            return (element, value, backend.writable(device, scope, element))
        }
        let writable = channelControls.filter { $0.2 }
        if !writable.isEmpty { return writable }
        if let master { return [(kAudioObjectPropertyElementMain, master, false)] }
        return channelControls
    }

    public static func read(device: AudioDeviceID, isInput: Bool, channels: Int) -> State {
        read(device: device, isInput: isInput, channels: channels, backend: hal)
    }

    static func read(device: AudioDeviceID, isInput: Bool, channels: Int, backend: Backend) -> State {
        let items = controls(device: device, isInput: isInput, channels: channels, backend: backend)
        return State(value: items.map { Double($0.value) }.max(),
                     writable: items.contains { $0.writable },
                     channelControls: items.contains { $0.element == kAudioObjectPropertyElementMain } ? 0 : items.count)
    }

    public static func set(_ value: Double, device: AudioDeviceID, isInput: Bool, channels: Int) throws {
        try set(value, device: device, isInput: isInput, channels: channels, backend: hal)
    }

    static func set(_ value: Double, device: AudioDeviceID, isInput: Bool, channels: Int,
                    backend: Backend) throws {
        guard value.isFinite else { throw VolumeError.unavailable }
        let items = controls(device: device, isInput: isInput, channels: channels, backend: backend)
            .filter { $0.writable }
        guard !items.isEmpty else { throw VolumeError.unavailable }
        let scope = isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let target = Float(min(1, max(0, value)))
        let maximum = items.map(\.value).max() ?? 0
        for (index, item) in items.enumerated() {
            // A linked per-channel slider retains the device's existing balance.
            let scalar = maximum > 0 ? target * item.value / maximum : target
            let status = backend.write(device, scope, item.element, scalar)
            if status != noErr {
                for previous in items.prefix(index) {
                    _ = backend.write(device, scope, previous.element, previous.value)
                }
                throw VolumeError.failed(status)
            }
        }
    }
}
