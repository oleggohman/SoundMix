import Foundation

/// Greedy peaking-filter design that pulls a measurement onto a target curve:
/// a small-scale AutoEq. The bands it returns are ordinary `PEQFilter`s, so
/// they flow through the draft/audition/Apply path like hand-dragged ones.
public enum AutoTune {

    public struct Options: Sendable {
        public var maxBands = 30
        /// Corrections smaller than this are not worth a filter.
        public var thresholdDB = 0.5
        /// Per-band clamp. The editor itself caps drags at ±24 dB.
        public var maxGainDB = 12.0
        public var qRange: ClosedRange<Double> = 0.5...8.0
        public var lowHz = 20.0
        public var highHz = 20_000.0
        public init() {}
    }

    /// Peaking bands that flatten `measurement` toward `target`. Both are
    /// levelled over 200 Hz–2 kHz first, so only the shape is corrected;
    /// absolute level stays the preamp's job.
    public static func bands(matching measurement: FrequencyResponse,
                             to target: FrequencyResponse,
                             sampleRate: Double = 48_000,
                             maxFrequency: Double = 20_000,
                             options: Options = .init()) -> [PEQFilter] {
        let m = measurement.normalized()
        let t = target.normalized()
        let low = max(options.lowHz, m.range.low, t.range.low)
        let high = min(options.highHz, m.range.high, t.range.high, maxFrequency)
        guard low > 0, high > low else { return [] }

        // Error on a 1/6-octave grid — fine enough to find peaks, and two grid
        // steps make one 1/3-octave interval for the fallback ladder.
        var grid: [Double] = []
        var hz = low
        while hz <= high {
            grid.append(hz)
            hz *= pow(2, 1.0 / 6.0)
        }
        guard grid.count > 2 else { return [] }
        let error = grid.map { t.magnitudeDB(at: $0) - m.magnitudeDB(at: $0) }

        // Local extrema of the error, largest correction first.
        var peaks: [(hz: Double, db: Double, halfWidth: Double)] = []
        for i in 1..<(grid.count - 1) where abs(error[i]) >= options.thresholdDB {
            let isMax = error[i] > error[i - 1] && error[i] >= error[i + 1]
            let isMin = error[i] < error[i - 1] && error[i] <= error[i + 1]
            guard isMax || isMin else { continue }
            peaks.append((grid[i], error[i], halfWidth(around: i, error: error, grid: grid)))
        }
        peaks.sort { abs($0.db) > abs($1.db) }
        if peaks.count > options.maxBands { peaks.removeLast(peaks.count - options.maxBands) }

        var filters = peaks.map { peak in
            PEQFilter(frequency: peak.hz,
                      gainDB: max(-options.maxGainDB, min(options.maxGainDB, peak.db)),
                      q: q(center: peak.hz, halfWidth: peak.halfWidth, in: options.qRange))
        }

        // Fallback ladder: stretches of error with no peak of their own still
        // drift, so cover them every 1/3 octave while the budget lasts.
        if filters.count < options.maxBands {
            for i in stride(from: 1, to: grid.count, by: 2) {
                guard filters.count < options.maxBands else { break }
                guard abs(error[i]) >= options.thresholdDB else { continue }
                let hz = grid[i]
                let crowded = filters.contains { abs(log2($0.frequency / hz)) < 1.0 / 3.0 }
                guard !crowded else { continue }
                filters.append(PEQFilter(frequency: hz,
                                         gainDB: max(-options.maxGainDB, min(options.maxGainDB, error[i])),
                                         q: q(center: hz, halfWidth: hz * (pow(2, 1.0 / 6.0) - 1),
                                              in: options.qRange)))
            }
        }

        // One overlap pass: re-read what the finished set still misses at each
        // centre and nudge that band by the shortfall, so neighbouring filters
        // do not double-count each other's correction.
        for _ in 0..<2 {
            for i in filters.indices {
                let centre = filters[i].frequency
                let need = t.magnitudeDB(at: centre) - m.magnitudeDB(at: centre)
                let have = filters.reduce(0.0) {
                    $0 + $1.biquad(sampleRate: sampleRate).magnitudeDB(at: centre, sampleRate: sampleRate)
                }
                filters[i].gainDB = max(-options.maxGainDB,
                                        min(options.maxGainDB,
                                            PEQFilter.limited(filters[i].gainDB + (need - have))))
            }
        }
        return filters.sorted { $0.frequency < $1.frequency }
    }

    /// Half-width, in Hz, of the region the extremum dominates: out to the
    /// nearest sign change of the error on each side, or one 1/6-octave span
    /// at minimum.
    private static func halfWidth(around i: Int, error: [Double], grid: [Double]) -> Double {
        var lo = i, hi = i
        while lo > 0 && (error[lo] >= 0) == (error[i] >= 0) { lo -= 1 }
        while hi < error.count - 1 && (error[hi] >= 0) == (error[i] >= 0) { hi += 1 }
        let span = (grid[hi] - grid[lo]) * 0.5
        return max(span, grid[i] * (pow(2, 1.0 / 6.0) - 1))
    }

    /// Q ≈ centre / bandwidth: a 1/3-octave span lands near the classic
    /// 1/3-octave Q of 4.3; wider plateaus get proportionally lower Q.
    private static func q(center: Double, halfWidth: Double, in range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, center / (2 * max(halfWidth, 1))))
    }
}
