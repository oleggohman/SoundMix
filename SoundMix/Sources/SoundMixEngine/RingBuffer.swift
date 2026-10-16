import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer of interleaved floats.
///
/// The input device and the output device run on separate Core Audio clocks, so
/// the capture callback writes here and the render callback reads. Nothing in
/// either path allocates or locks.
public final class FloatRingBuffer: @unchecked Sendable {
    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int                 // in frames
    private let channels: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    private let targetFrames: Int
    private let kernels: [Float]
    private static let taps = 32
    private static let phases = 256
    private var primed = false
    private var fraction = 0.0
    public private(set) var readRatio = 1.0

    /// Diagnostics counters, written on the producer/consumer threads and read
    /// for telemetry, so they accumulate atomically.
    private let overrunCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)
    public var overruns: Int { overrunCount.load(ordering: .acquiring) }
    public var underruns: Int { underrunCount.load(ordering: .acquiring) }

    public init(frames: Int, channels: Int, targetFrames: Int = 0) {
        self.capacity = max(frames, 2)
        self.channels = max(channels, 1)
        self.targetFrames = min(max(0, targetFrames), max(0, self.capacity - Self.taps - 2))
        self.kernels = targetFrames > 0 ? Self.makeKernels() : []
        self.storage = .allocate(capacity: self.capacity * self.channels)
        self.storage.initialize(repeating: 0, count: self.capacity * self.channels)
    }

    deinit {
        storage.deinitialize(count: capacity * channels)
        storage.deallocate()
    }

    public var framesAvailable: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return w >= r ? w - r : capacity - r + w
    }

    public var framesFree: Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        return capacity - (w >= r ? w - r : capacity - r + w) - 1
    }

    /// Only for a stopped stream (both sides quiescent): the buffer contents
    /// and the interpolator's fractional position are reset without any
    /// synchronization against a live producer or consumer.
    public func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        storage.update(repeating: 0, count: capacity * channels)
        primed = false; fraction = 0; readRatio = 1
        overrunCount.store(0, ordering: .relaxed)
        underrunCount.store(0, ordering: .relaxed)
    }

    /// Producer side. Drops the block and counts an overrun when there is no room.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frames: Int) -> Bool {
        guard frames <= framesFree else { overrunCount.wrappingAdd(1, ordering: .relaxed); return false }
        var w = writeIndex.load(ordering: .relaxed)
        var remaining = frames
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - w)
            storage.advanced(by: w * channels)
                .update(from: source.advanced(by: offset * channels), count: chunk * channels)
            w = (w + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }
        writeIndex.store(w, ordering: .releasing)
        return true
    }

    /// Consumer side. Fills the tail with silence and counts an underrun when short.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let available = framesAvailable
        let toRead = min(frames, available)
        if toRead < frames {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            destination.advanced(by: toRead * channels)
                .update(repeating: 0, count: (frames - toRead) * channels)
        }
        guard toRead > 0 else { return false }
        var r = readIndex.load(ordering: .relaxed)
        var remaining = toRead
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - r)
            destination.advanced(by: offset * channels)
                .update(from: storage.advanced(by: r * channels), count: chunk * channels)
            r = (r + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }
        readIndex.store(r, ordering: .releasing)
        return toRead == frames
    }
    /// Consumer-only clock bridge. Prefills before playback and gently adjusts
    /// the consumption rate to hold the requested safety margin. A precomputed
    /// windowed-sinc interpolator avoids linear interpolation's treble loss.
    @discardableResult
    public func readAdaptive(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard targetFrames > 0 else { return read(into: destination, frames: frames) }
        let available = framesAvailable
        if !primed {
            guard available >= max(targetFrames, frames) + Self.taps else {
                destination.update(repeating: 0, count: frames * channels)
                return true // Intentional startup/recovery buffering, not a dropout.
            }
            primed = true
        }
        let error = Double(available - targetFrames - Self.taps)
        let desired = 1 + min(0.005, max(-0.005, error * 0.000002))
        readRatio += (desired - readRatio) * 0.01
        let required = Int(ceil(fraction + Double(frames) * readRatio)) + Self.taps
        guard available >= required else {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            primed = false
            // Play whatever did arrive and zero-fill the tail, rather than
            // silencing the whole block. A plain integer read of `toRead`
            // frames is safe: the interpolator's history window is only
            // needed once it resumes, after re-priming.
            let toRead = min(frames, available)
            if toRead > 0 { _ = read(into: destination, frames: toRead) }
            destination.advanced(by: toRead * channels)
                .update(repeating: 0, count: (frames - toRead) * channels)
            return false
        }
        var r = readIndex.load(ordering: .relaxed)
        for f in 0..<frames {
            let phase = fraction * Double(Self.phases)
            let bin = min(Self.phases - 1, Int(phase))
            let blend = Float(phase - Double(bin))
            for c in 0..<channels {
                var value: Float = 0
                for tap in 0..<Self.taps {
                    let a = kernels[bin * Self.taps + tap]
                    let b = kernels[(bin + 1) * Self.taps + tap]
                    value += storage[((r + tap) % capacity) * channels + c] * (a + (b - a) * blend)
                }
                destination[f * channels + c] = value
            }
            fraction += readRatio
            let consumed = Int(fraction)
            fraction -= Double(consumed)
            r = (r + consumed) % capacity
        }
        readIndex.store(r, ordering: .releasing)
        return true
    }

    private static func makeKernels() -> [Float] {
        var result = [Float](repeating: 0, count: (phases + 1) * taps)
        for phase in 0...phases {
            var sum = 0.0
            for tap in 0..<taps {
                let x = Double(tap - (taps / 2 - 1)) - Double(phase) / Double(phases)
                let sinc = abs(x) < 1e-9 ? 1 : sin(.pi * x) / (.pi * x)
                let window = 0.42 + 0.5 * cos(.pi * x / Double(taps / 2))
                    + 0.08 * cos(2 * .pi * x / Double(taps / 2))
                let value = sinc * window
                result[phase * taps + tap] = Float(value)
                sum += value
            }
            for tap in 0..<taps { result[phase * taps + tap] /= Float(sum) }
        }
        return result
    }

}
