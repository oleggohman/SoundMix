import Foundation
import CoreAudio
import AudioToolbox

/// A Core Audio device as the interface needs to see it.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    public let isDefaultInput: Bool
    public let isDefaultOutput: Bool
    public let transportType: String

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    public var channelSummary: String {
        "\(inputChannels) in · \(outputChannels) out"
    }
}

/// Enumerates Core Audio devices and reports changes through a callback.
///
/// The original app shells out to `--list-devices` and scrapes the text with a
/// regex, then polls on a timer. This listens to the HAL directly, so a device
/// appearing or disappearing is a notification rather than a poll.
public final class AudioDeviceDirectory: @unchecked Sendable {

    public private(set) var devices: [AudioDevice] = []
    /// Called on the main queue whenever the device list or defaults change.
    public var onChange: (([AudioDevice]) -> Void)?

    private var listenerInstalled = false
    private let queue = DispatchQueue(label: "io.soundmix.devicedirectory")

    public init() {
        refresh()
        installListeners()
    }

    deinit { removeListeners() }

    public func refresh() {
        let list = Self.enumerate()
        devices = list
    }

    public func device(withUID uid: String) -> AudioDevice? {
        devices.first { $0.uid == uid }
    }
    public func device(withID id: AudioDeviceID) -> AudioDevice? {
        devices.first { $0.id == id }
    }

    public var inputDevices: [AudioDevice] { devices.filter(\.hasInput) }
    public var outputDevices: [AudioDevice] { devices.filter(\.hasOutput) }

    // MARK: - Listeners

    private static let listenedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self else { return }
        let list = Self.enumerate()
        DispatchQueue.main.async {
            self.devices = list
            self.onChange?(list)
        }
    }

    private func installListeners() {
        guard !listenerInstalled else { return }
        for selector in Self.listenedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listenerBlock)
        }
        listenerInstalled = true
    }

    private func removeListeners() {
        guard listenerInstalled else { return }
        for selector in Self.listenedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listenerBlock)
        }
        listenerInstalled = false
    }

    // MARK: - Enumeration

    public static func enumerate() -> [AudioDevice] {
        let ids = systemDeviceIDs()
        let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        return ids.compactMap { id in
            let inCh = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outCh = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard inCh > 0 || outCh > 0 else { return nil }
            return AudioDevice(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "device-\(id)",
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Device \(id)",
                manufacturer: stringProperty(id, kAudioObjectPropertyManufacturer) ?? "",
                inputChannels: inCh,
                outputChannels: outCh,
                nominalSampleRate: nominalSampleRate(id),
                availableSampleRates: availableSampleRates(id),
                isDefaultInput: id == defaultIn,
                isDefaultOutput: id == defaultOut,
                transportType: transportName(id))
        }
    }

    static func systemDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    public static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v as String
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }

    @discardableResult
    public static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        var rates = Set<Double>()
        let common: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]
        for r in ranges {
            if r.mMinimum == r.mMaximum { rates.insert(r.mMinimum) }
            else { for c in common where c >= r.mMinimum && c <= r.mMaximum { rates.insert(c) } }
        }
        return rates.sorted()
    }

    static func transportName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return "" }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn:     return "Built-in"
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeAggregate:   return "Aggregate"
        case kAudioDeviceTransportTypeVirtual:     return "Virtual"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
        case kAudioDeviceTransportTypePCI:         return "PCI"
        case kAudioDeviceTransportTypeFireWire:    return "FireWire"
        default: return ""
        }
    }
}
