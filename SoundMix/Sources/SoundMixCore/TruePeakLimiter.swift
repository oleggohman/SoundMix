import Foundation

/// Look-ahead true-peak limiter for the stereo bus.
///
/// The original renderer offers only `--clip-output` (hard clip to ±1), which
/// the GUI does not even expose, so the only protection against the matrix's
/// gain is a blunt −9.5 dB preamp. This limiter lets the downmix run at a
/// useful level and still guarantees the ceiling.
///
/// Design: 4× polyphase-FIR oversampled peak detection (so inter-sample peaks
/// are caught), a look-ahead delay line, and a smoothed gain envelope with
/// separate attack and release so gain reduction does not modulate audibly.
public final class TruePeakLimiter {

    public struct Settings: Equatable, Sendable {
        /// Output ceiling in dBTP.
        public var ceilingDB: Double
        /// Look-ahead in milliseconds; also the limiter's added latency.
        public var lookaheadMS: Double
        /// Release time constant in milliseconds.
        public var releaseMS: Double
        public var enabled: Bool

        public init(ceilingDB: Double = -1.0, lookaheadMS: Double = 2.0,
                    releaseMS: Double = 80.0, enabled: Bool = true) {
            self.ceilingDB = ceilingDB
            self.lookaheadMS = lookaheadMS
            self.releaseMS = releaseMS
            self.enabled = enabled
        }
    }

    public private(set) var settings: Settings
    private var sampleRate: Double

    private var delayL: [Double] = []
    private var delayR: [Double] = []
    private var writeIndex = 0
    private var lookaheadSamples = 1

    private var envelope: Double = 1.0        // current gain multiplier
    private var releaseCoefficient: Double = 0
    private var ceilingLinear: Double = 1

    /// Highest gain reduction seen since the last `takeGainReductionDB()`.
    private var peakReduction: Double = 0

    /// 4× upsampling kernel, a windowed sinc evaluated at the three
    /// intermediate phases. Phase 0 is the sample itself.
    private static let phases: [[Double]] = makePhases(taps: 16, factor: 4)
    private var historyL: [Double] = Array(repeating: 0, count: 16)
    private var historyR: [Double] = Array(repeating: 0, count: 16)
    private var holdSamples = 0
    private var historyIndex = 0

    public init(sampleRate: Double = 48_000, settings: Settings = Settings()) {
        self.sampleRate = sampleRate
        self.settings = settings
        configure()
    }

    public var latencySamples: Int { settings.enabled ? lookaheadSamples : 0 }
    public var latencyMS: Double { Double(latencySamples) / sampleRate * 1000 }

    public func update(settings: Settings, sampleRate: Double) {
        let needsResize = settings.lookaheadMS != self.settings.lookaheadMS || sampleRate != self.sampleRate
        self.settings = settings
        self.sampleRate = sampleRate
        if needsResize { configure() } else { refreshCoefficients() }
    }

    public func reset() {
        for i in delayL.indices { delayL[i] = 0; delayR[i] = 0 }
        for i in historyL.indices { historyL[i] = 0; historyR[i] = 0 }
        holdSamples = 0
        writeIndex = 0
        historyIndex = 0
        envelope = 1
        peakReduction = 0
    }

    private func configure() {
        lookaheadSamples = max(1, Int((settings.lookaheadMS / 1000.0 * sampleRate).rounded()))
        delayL = Array(repeating: 0, count: lookaheadSamples)
        delayR = Array(repeating: 0, count: lookaheadSamples)
        writeIndex = 0
        envelope = 1
        refreshCoefficients()
    }

    private func refreshCoefficients() {
        ceilingLinear = pow(10, settings.ceilingDB / 20)
        let tau = max(settings.releaseMS, 1.0) / 1000.0
        releaseCoefficient = exp(-1.0 / (tau * sampleRate))
    }

    /// Gain reduction in dB since the previous call, then resets the hold.
    public func takeGainReductionDB() -> Double {
        let v = peakReduction
        peakReduction = 0
        return v
    }

    /// Process one stereo frame in place.
    @inline(__always)
    public func process(_ left: inout Double, _ right: inout Double) {
        guard settings.enabled else { return }

        // A non-finite sample (a misbehaving capture device) must stop here:
        // NaN compares false against everything, which would otherwise leave
        // the gain envelope untouched and pass NaN to the output.
        let inL = left.isFinite ? left : 0
        let inR = right.isFinite ? right : 0

        // True-peak estimate of the incoming frame, using the louder channel.
        historyL[historyIndex] = inL
        historyR[historyIndex] = inR
        historyIndex = (historyIndex + 1) % historyL.count
        let peak = max(truePeak(inL, history: historyL), truePeak(inR, history: historyR))

        // Target gain that would bring this peak to the ceiling.
        let target = peak > ceilingLinear ? ceilingLinear / peak : 1.0

        // Attack is instantaneous against the look-ahead window; release is smoothed.
        if target < envelope {
            envelope = target
            holdSamples = lookaheadSamples + historyL.count
        } else if holdSamples > 0 {
            holdSamples -= 1
        } else {
            envelope = target + (envelope - target) * releaseCoefficient
        }

        let reductionDB = envelope < 1 ? -20 * log10(max(envelope, 1e-6)) : 0
        if reductionDB > peakReduction { peakReduction = reductionDB }

        // Read the delayed sample, then write the new one.
        let outL = delayL[writeIndex], outR = delayR[writeIndex]
        delayL[writeIndex] = inL
        delayR[writeIndex] = inR
        writeIndex = (writeIndex + 1) % lookaheadSamples

        left = clampToCeiling(outL * envelope)
        right = clampToCeiling(outR * envelope)
    }

    @inline(__always)
    private func clampToCeiling(_ v: Double) -> Double {
        // The envelope already holds the signal down; this only guards against
        // the residual error of the true-peak estimate. A non-finite value is
        // muted rather than clamped: min/max propagate NaN, they do not trap it.
        guard v.isFinite else { return 0 }
        return min(max(v, -ceilingLinear), ceilingLinear)
    }

    /// Peak magnitude of the 4× oversampled signal around the newest sample.
    @inline(__always)
    private func truePeak(_ sample: Double, history: [Double]) -> Double {
        var peak = abs(sample)
        for phase in Self.phases {
            var acc = 0.0
            var idx = historyIndex
            for tap in phase {
                acc += tap * history[idx]
                idx = (idx + 1) % history.count
            }
            peak = max(peak, abs(acc))
        }
        return peak
    }

    // Copy into preallocated storage when adopting a prepared configuration.
    func inheritHistory(from previous: TruePeakLimiter) {
        guard delayL.count == previous.delayL.count,
              settings.enabled == previous.settings.enabled else { return }
        for i in delayL.indices { delayL[i] = previous.delayL[i]; delayR[i] = previous.delayR[i] }
        for i in historyL.indices { historyL[i] = previous.historyL[i]; historyR[i] = previous.historyR[i] }
        writeIndex = previous.writeIndex
        historyIndex = previous.historyIndex
        envelope = previous.envelope
        holdSamples = previous.holdSamples
    }

    /// Windowed-sinc interpolation kernels for the fractional phases 1/4, 2/4, 3/4.
    private static func makePhases(taps: Int, factor: Int) -> [[Double]] {
        var result: [[Double]] = []
        // Integer origin keeps all three fractional phases: 1/4, 1/2, 3/4.
        let center = Double(taps / 2 - 1)
        for p in 1..<factor {
            let offset = Double(p) / Double(factor)
            var kernel: [Double] = []
            kernel.reserveCapacity(taps)
            var sum = 0.0
            for n in 0..<taps {
                let x = Double(n) - center - offset
                let sinc = abs(x) < 1e-9 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                // Blackman window over the tap span.
                let t = Double(n) / Double(taps - 1)
                let w = 0.42 - 0.5 * cos(2 * Double.pi * t) + 0.08 * cos(4 * Double.pi * t)
                let v = sinc * w
                kernel.append(v)
                sum += v
            }
            if sum != 0 { kernel = kernel.map { $0 / sum } }
            result.append(kernel)
        }
        return result
    }
}
