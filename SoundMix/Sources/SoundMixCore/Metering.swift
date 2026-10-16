import Foundation

/// Peak / RMS meter with exponential decay, in dBFS.
public struct LevelMeter: Sendable {
    public private(set) var peak: Double = 0
    public private(set) var rms: Double = 0
    public private(set) var clipCount: Int = 0

    private var decay: Double = 0.9995
    private var rmsCoefficient: Double = 0.999
    private var meanSquare: Double = 0
    private var clipArmed = true

    public init() {}

    public mutating func configure(sampleRate: Double, peakFallDBPerSecond: Double = 20,
                                   rmsWindowMS: Double = 300) {
        decay = pow(10, -peakFallDBPerSecond / 20 / sampleRate)
        rmsCoefficient = exp(-1.0 / (max(rmsWindowMS, 1) / 1000 * sampleRate))
    }

    @inline(__always)
    public mutating func accumulate(_ sample: Double) {
        // A non-finite sample must not enter the one-pole: meanSquare would
        // latch NaN permanently and the RMS readout would never recover.
        guard sample.isFinite else { return }
        let a = abs(sample)
        if a > peak { peak = a } else { peak *= decay }
        meanSquare = a * a + (meanSquare - a * a) * rmsCoefficient
        rms = meanSquare.squareRoot()
        if a >= 0.999_85 {
            if clipArmed { clipCount += 1; clipArmed = false }
        } else if a < 0.98 {
            clipArmed = true
        }
    }

    public var peakDB: Double { LevelMeter.dB(peak) }
    public var rmsDB: Double { LevelMeter.dB(rms) }

    public mutating func resetClipCount() { clipCount = 0 }
    public mutating func reset() { peak = 0; rms = 0; meanSquare = 0; clipCount = 0; clipArmed = true }

    public static func dB(_ linear: Double) -> Double {
        linear > 1e-8 ? 20 * log10(linear) : -.infinity
    }
}

/// A snapshot of everything the interface needs to draw, copied out of the
/// audio thread under a lock-free swap.
public struct RenderSnapshot: Sendable, Equatable {
    public var bedPeakDB: [Double]          // 16 entries
    public var outputPeakDB: (Double, Double)
    public var outputRMSDB: (Double, Double)
    public var clipLeft: Int
    public var clipRight: Int
    public var gainReductionDB: Double
    public var appliedTrimDB: Double
    public var latencyMS: Double
    public var sampleRate: Double
    public var isRunning: Bool
    public var underruns: Int

    public init(bedPeakDB: [Double] = Array(repeating: -.infinity, count: BedChannel.count),
                outputPeakDB: (Double, Double) = (-.infinity, -.infinity),
                outputRMSDB: (Double, Double) = (-.infinity, -.infinity),
                clipLeft: Int = 0, clipRight: Int = 0,
                gainReductionDB: Double = 0, appliedTrimDB: Double = 0,
                latencyMS: Double = 0, sampleRate: Double = 48_000,
                isRunning: Bool = false, underruns: Int = 0) {
        self.bedPeakDB = bedPeakDB
        self.outputPeakDB = outputPeakDB
        self.outputRMSDB = outputRMSDB
        self.clipLeft = clipLeft
        self.clipRight = clipRight
        self.gainReductionDB = gainReductionDB
        self.appliedTrimDB = appliedTrimDB
        self.latencyMS = latencyMS
        self.sampleRate = sampleRate
        self.isRunning = isRunning
        self.underruns = underruns
    }

    public static func == (a: RenderSnapshot, b: RenderSnapshot) -> Bool {
        a.bedPeakDB == b.bedPeakDB && a.outputPeakDB == b.outputPeakDB
            && a.outputRMSDB == b.outputRMSDB && a.clipLeft == b.clipLeft
            && a.clipRight == b.clipRight && a.gainReductionDB == b.gainReductionDB
            && a.appliedTrimDB == b.appliedTrimDB && a.latencyMS == b.latencyMS
            && a.sampleRate == b.sampleRate && a.isRunning == b.isRunning
            && a.underruns == b.underruns
    }
}
