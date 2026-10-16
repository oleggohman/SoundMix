import Foundation
import CoreAudio
import AudioToolbox
import AudioUnit
import Synchronization

public enum EngineError: LocalizedError {
    case deviceUnavailable(String)
    case componentMissing
    case osStatus(String, OSStatus)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let s): return s
        case .componentMissing:         return "The system HAL audio component is unavailable."
        case .osStatus(let what, let s): return "\(what) failed (Core Audio status \(s))."
        case .unsupported(let s):       return s
        }
    }
}

public enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    public var isRunning: Bool { self == .running }
}

/// Live 9.1.6-bed → stereo renderer built directly on two AUHAL units.
///
/// One process, no helper binaries, no localhost control channel. The capture
/// unit writes into a lock-free ring; the render unit pulls from it, folds the
/// bed and plays it. Device loss arrives as a Core Audio notification rather
/// than being inferred from a log line.
public final class SoundMixEngine: @unchecked Sendable {

    public let processor = SoundMixProcessor()

    public private(set) var state: EngineState = .stopped {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { self.onStateChange?(s) }
        }
    }

    public var onStateChange: ((EngineState) -> Void)?
    public var onLog: ((String) -> Void)?

    public struct Options: Equatable, Sendable {
        public var framesPerBuffer: Int
        /// Extra buffering between the two device clocks, in milliseconds.
        public var safetyBufferMS: Double
        public init(framesPerBuffer: Int = 128, safetyBufferMS: Double = 20) {
            self.framesPerBuffer = framesPerBuffer
            self.safetyBufferMS = safetyBufferMS
        }
    }

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var ring: FloatRingBuffer?

    private var inputChannels = 0
    private var outputChannels = 0
    private var sampleRate: Double = 48_000
    private var maxFrames = 2048

    private var captureList: UnsafeMutableAudioBufferListPointer?
    private var captureStorage: UnsafeMutablePointer<Float>?
    private var pullStorage: UnsafeMutablePointer<Float>?
    private var mixStorage: UnsafeMutablePointer<Float>?

    /// Capture-side diagnostics. Without these a dead input path looks
    /// identical to silence, which is exactly what happened in testing.
    /// Written on the capture thread and read for telemetry, so they
    /// accumulate atomically.
    private let captureCallbacks = Atomic<Int>(0)
    private let captureFramesDelivered = Atomic<Int>(0)
    private let captureRenderErrors = Atomic<Int>(0)
    private let lastCaptureError = Atomic<OSStatus>(0)
    private let captureOversize = Atomic<Int>(0)
    /// Set on the control thread before the units start; never touched again
    /// while running, so a plain var is fine.
    public private(set) var startCount = 0

    /// Thread-safe read accessors for telemetry.
    public var captureCallbackCount: Int { captureCallbacks.load(ordering: .acquiring) }
    public var captureFramesDeliveredCount: Int { captureFramesDelivered.load(ordering: .acquiring) }
    public var captureRenderErrorCount: Int { captureRenderErrors.load(ordering: .acquiring) }
    public var lastCaptureErrorCode: OSStatus { lastCaptureError.load(ordering: .acquiring) }
    /// Capture slices larger than the allocated buffers, which are dropped
    /// rather than rendered.
    public var captureOversizeCount: Int { captureOversize.load(ordering: .acquiring) }

    private var inputDeviceID: AudioDeviceID = 0
    private var outputDeviceID: AudioDeviceID = 0
    private var aliveListeners: [(AudioDeviceID, AudioObjectPropertyListenerBlock)] = []
    private let listenerQueue = DispatchQueue(label: "io.soundmix.enginelisteners")

    /// Device settings the engine changes while running, so `teardown()` can
    /// put them back. They are system-global — other apps hear them too —
    /// which is exactly why they must not outlive the session.
    private var savedInputSampleRate: Double?
    private var savedInputBufferFrames: UInt32?
    private var savedOutputBufferFrames: UInt32?

    public init() {}
    deinit { stop() }

    public var currentSampleRate: Double { sampleRate }

    // MARK: - Lifecycle

    public func start(input: AudioDevice, output: AudioDevice,
                      configuration: ProcessorConfiguration,
                      options: Options) throws {
        stop()
        state = .starting

        do {
            try validate(input: input, output: output, configuration: configuration)
            try bringUp(input: input, output: output, configuration: configuration, options: options)
            state = .running
            log("Rendering \(configuration.layout.name) from “\(input.name)” to “\(output.name)” at \(Int(sampleRate)) Hz, \(options.framesPerBuffer)-frame buffers.")
            let trim = configuration.totalTrimDB
            log(String(format: "Matrix “%@” · worst-case %+.1f dB · applied trim %+.1f dB · chain latency %.1f ms",
                       configuration.recipe.name,
                       configuration.effectiveMatrix.worstCasePeakGainDB,
                       trim,
                       processor.latencyMS))
        } catch {
            teardown()
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            throw error
        }
    }

    public func stop() {
        guard inputUnit != nil || outputUnit != nil else {
            if state != .stopped, case .failed = state {} else { state = .stopped }
            return
        }
        teardown()
        processor.markStopped()
        state = .stopped
        log("Stopped.")
    }

    public func apply(_ configuration: ProcessorConfiguration) {
        processor.apply(configuration)
    }

    /// The configuration the processor is currently rendering. Exposed so the
    /// interface does not need to reach through to the processor itself.
    public var currentConfiguration: ProcessorConfiguration { processor.configuration }
    /// The processing chain's latency in milliseconds, at the current settings.
    public var chainLatencyMS: Double { processor.latencyMS }
    /// The latest render snapshot: meters, clipping, underruns, latency.
    public func snapshot() -> RenderSnapshot { processor.snapshot() }

    private func log(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }

    // MARK: - Validation

    private func validate(input: AudioDevice, output: AudioDevice,
                          configuration: ProcessorConfiguration) throws {
        let needed = configuration.layout.requiredInputChannels
        guard input.inputChannels >= needed else {
            throw EngineError.unsupported(
                "“\(input.name)” has \(input.inputChannels) input channels but the \(configuration.layout.name) layout needs \(needed). Pick a smaller layout or another device.")
        }
        guard output.outputChannels >= 2 else {
            throw EngineError.unsupported(
                "“\(output.name)” has \(output.outputChannels) output channel\(output.outputChannels == 1 ? "" : "s"); stereo playback needs at least 2.")
        }
    }

    // MARK: - Bring-up

    private func bringUp(input: AudioDevice, output: AudioDevice,
                         configuration: ProcessorConfiguration,
                         options: Options) throws {
        inputDeviceID = input.id
        outputDeviceID = output.id
        inputChannels = input.inputChannels
        outputChannels = output.outputChannels

        // Run both devices at the output's rate; the renderer is rate-agnostic.
        //
        // The rates are re-read from the HAL here rather than taken from the
        // cached device list: a device's rate can change after enumeration —
        // another app, or this one on a previous run, may have moved it — and
        // acting on a stale value leaves the capture unit converting between
        // rates that do not match, which produces silence rather than an error.
        let liveOutputRate = AudioDeviceDirectory.nominalSampleRate(output.id)
        sampleRate = liveOutputRate > 0 ? liveOutputRate : 48_000

        let liveInputRate = AudioDeviceDirectory.nominalSampleRate(input.id)
        if abs(liveInputRate - sampleRate) > 0.5 {
            savedInputSampleRate = liveInputRate
            _ = AudioDeviceDirectory.setNominalSampleRate(input.id, sampleRate)
            // Setting the rate is asynchronous in the HAL; confirm it landed
            // instead of assuming it did.
            var settled = AudioDeviceDirectory.nominalSampleRate(input.id)
            var waited = 0
            while abs(settled - sampleRate) > 0.5 && waited < 20 {
                usleep(25_000)
                settled = AudioDeviceDirectory.nominalSampleRate(input.id)
                waited += 1
            }
            guard abs(settled - sampleRate) <= 0.5 else {
                throw EngineError.unsupported(
                    "“\(input.name)” stayed at \(Int(settled)) Hz and will not follow “\(output.name)” to \(Int(sampleRate)) Hz. Set both to the same rate in Audio MIDI Setup, or pick an output that already matches.")
            }
            log("Moved “\(input.name)” to \(Int(sampleRate)) Hz to match “\(output.name)”; it will be put back on stop.")
        }

        let frames = max(32, min(options.framesPerBuffer, 4096))
        savedInputBufferFrames = bufferFrameSize(input.id) ?? savedInputBufferFrames
        savedOutputBufferFrames = bufferFrameSize(output.id) ?? savedOutputBufferFrames
        if setBufferFrameSize(input.id, frames) != noErr {
            log("“\(input.name)” kept its own buffer size; the engine adapts.")
        }
        if setBufferFrameSize(output.id, frames) != noErr {
            log("“\(output.name)” kept its own buffer size; the engine adapts.")
        }
        maxFrames = max(frames * 4, 2048)

        guard options.safetyBufferMS.isFinite, (0...2000).contains(options.safetyBufferMS) else {
            throw EngineError.unsupported("Safety buffer must be between 0 and 2000 ms.")
        }
        let ringFrames = max(Int(options.safetyBufferMS / 1000 * sampleRate), frames * 4)
        ring = FloatRingBuffer(frames: ringFrames * 2 + maxFrames * 2 + 64,
                               channels: inputChannels, targetFrames: ringFrames)

        captureStorage = .allocate(capacity: maxFrames * inputChannels)
        captureStorage?.initialize(repeating: 0, count: maxFrames * inputChannels)
        pullStorage = .allocate(capacity: maxFrames * inputChannels)
        pullStorage?.initialize(repeating: 0, count: maxFrames * inputChannels)
        mixStorage = .allocate(capacity: maxFrames * 2)
        mixStorage?.initialize(repeating: 0, count: maxFrames * 2)

        let list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(mNumberChannels: UInt32(inputChannels),
                              mDataByteSize: UInt32(maxFrames * inputChannels * MemoryLayout<Float>.size),
                              mData: UnsafeMutableRawPointer(captureStorage))
        captureList = list

        captureCallbacks.store(0, ordering: .relaxed)
        captureFramesDelivered.store(0, ordering: .relaxed)
        captureRenderErrors.store(0, ordering: .relaxed)
        lastCaptureError.store(0, ordering: .relaxed)
        captureOversize.store(0, ordering: .relaxed)
        startCount += 1

        processor.applyNow(configuration)
        processor.prepare(sampleRate: sampleRate)
        processor.applyNow(configuration)
        processor.reset()

        inputUnit = try makeHALUnit()
        outputUnit = try makeHALUnit()
        try configureInputUnit(frames: frames)
        try configureOutputUnit(frames: frames)

        try check(AudioUnitInitialize(inputUnit!), "Initialising the capture unit")
        try check(AudioUnitInitialize(outputUnit!), "Initialising the playback unit")

        installAliveListener(for: input.id, label: input.name, role: "input")
        if output.id != input.id {
            installAliveListener(for: output.id, label: output.name, role: "output")
        }

        try check(AudioOutputUnitStart(inputUnit!), "Starting capture")
        try check(AudioOutputUnitStart(outputUnit!), "Starting playback")
    }

    private func makeHALUnit() throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.componentMissing
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), "Creating a HAL unit")
        guard let unit else { throw EngineError.componentMissing }
        return unit
    }

    private func configureInputUnit(frames: Int) throws {
        guard let unit = inputUnit else { return }
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "Enabling device input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)),
                  "Disabling output on the capture unit")
        var device = inputDeviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Selecting the input device")

        var format = Self.streamFormat(sampleRate: sampleRate, channels: inputChannels)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "Setting the capture format")

        var slice = UInt32(maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &slice, UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Installing the capture callback")
        _ = frames
    }

    private func configureOutputUnit(frames: Int) throws {
        guard let unit = outputUnit else { return }
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "Enabling device output")
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
        var device = outputDeviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "Selecting the output device")

        var format = Self.streamFormat(sampleRate: sampleRate, channels: outputChannels)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &format,
                                       UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  "Setting the playback format")

        var slice = UInt32(maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &slice, UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &callback,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Installing the render callback")
        _ = frames
    }

    static func streamFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    private func setBufferFrameSize(_ device: AudioDeviceID, _ frames: Int) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(frames)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The device's current buffer frame size, or nil if it cannot be read.
    private func bufferFrameSize(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Put back the device settings the session changed. Best-effort: a device
    /// that vanished cannot accept writes, and a refused restore is logged for
    /// the user rather than failing the teardown it lives in.
    private func restoreDeviceSettings() {
        if let rate = savedInputSampleRate, inputDeviceID != 0 {
            if AudioDeviceDirectory.setNominalSampleRate(inputDeviceID, rate) {
                log("Restored input device to \(Int(rate)) Hz.")
            }
        }
        if let frames = savedInputBufferFrames, inputDeviceID != 0 {
            _ = setBufferFrameSize(inputDeviceID, Int(frames))
        }
        if let frames = savedOutputBufferFrames, outputDeviceID != 0 {
            _ = setBufferFrameSize(outputDeviceID, Int(frames))
        }
        savedInputSampleRate = nil
        savedInputBufferFrames = nil
        savedOutputBufferFrames = nil
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw EngineError.osStatus(what, status) }
    }

    // MARK: - Device loss

    private func installAliveListener(for device: AudioDeviceID, label: String, role: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &alive)
            if alive == 0 {
                DispatchQueue.main.async {
                    self.teardown()
                    self.processor.markStopped()
                    self.state = .failed("The \(role) device “\(label)” was removed.")
                }
            }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block)
        aliveListeners.append((device, block))
    }

    private func removeAliveListeners() {
        for (device, block) in aliveListeners {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &address, listenerQueue, block)
        }
        aliveListeners.removeAll()
    }

    private func teardown() {
        removeAliveListeners()
        for unit in [inputUnit, outputUnit].compactMap({ $0 }) {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        outputUnit = nil
        restoreDeviceSettings()
        if let list = captureList { free(list.unsafeMutablePointer) ; captureList = nil }
        captureStorage?.deallocate(); captureStorage = nil
        pullStorage?.deallocate(); pullStorage = nil
        mixStorage?.deallocate(); mixStorage = nil
        ring = nil
    }

    // MARK: - Real-time callbacks

    fileprivate func capture(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             timestamp: UnsafePointer<AudioTimeStamp>,
                             bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit = inputUnit, let list = captureList, let ring else { return noErr }
        guard Int(frames) <= maxFrames else {
            captureOversize.wrappingAdd(1, ordering: .relaxed)
            return noErr
        }

        captureCallbacks.wrappingAdd(1, ordering: .relaxed)
        list[0].mDataByteSize = frames * UInt32(inputChannels * MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr, let data = list[0].mData else {
            captureRenderErrors.wrappingAdd(1, ordering: .relaxed)
            lastCaptureError.store(status, ordering: .relaxed)
            return status
        }

        ring.write(data.assumingMemoryBound(to: Float.self), frames: Int(frames))
        captureFramesDelivered.wrappingAdd(Int(frames), ordering: .relaxed)
        return noErr
    }

    fileprivate func render(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let ring, let pull = pullStorage, let mix = mixStorage,
              Int(frames) <= maxFrames else {
            for b in buffers { memset(b.mData, 0, Int(b.mDataByteSize)) }
            return noErr
        }

        if !ring.readAdaptive(into: pull, frames: Int(frames)) {
            processor.noteUnderrun()
        }
        processor.process(input: pull, inputChannels: inputChannels,
                          frames: Int(frames), output: mix)

        // Interleaved device buffer: fill the first two channels, silence the rest.
        if buffers.count == 1, let raw = buffers[0].mData {
            let out = raw.assumingMemoryBound(to: Float.self)
            let ch = Int(buffers[0].mNumberChannels)
            if ch == 2 {
                out.update(from: mix, count: Int(frames) * 2)
            } else {
                for f in 0..<Int(frames) {
                    let base = f * ch
                    for c in 0..<ch { out[base + c] = c < 2 ? mix[f * 2 + c] : 0 }
                }
            }
        } else {
            // Non-interleaved: one buffer per channel.
            for (index, buffer) in buffers.enumerated() {
                guard let raw = buffer.mData else { continue }
                let out = raw.assumingMemoryBound(to: Float.self)
                if index < 2 {
                    for f in 0..<Int(frames) { out[f] = mix[f * 2 + index] }
                } else {
                    memset(raw, 0, Int(buffer.mDataByteSize))
                }
            }
        }
        return noErr
    }
}

// MARK: - C callbacks

private func captureCallback(refCon: UnsafeMutableRawPointer,
                             flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             timestamp: UnsafePointer<AudioTimeStamp>,
                             bus: UInt32, frames: UInt32,
                             ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<SoundMixEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.capture(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
}

private func renderCallback(refCon: UnsafeMutableRawPointer,
                            flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32,
                            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<SoundMixEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(frames: frames, ioData: ioData)
}
