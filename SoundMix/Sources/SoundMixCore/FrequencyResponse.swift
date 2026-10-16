import Foundation

/// A measured magnitude response — an earphone or speaker curve exported from
/// AutoEQ, oratory1990, a squig.link database, or REW.
///
/// Pairing one with an EQ profile is what makes the correction legible: the
/// filters alone tell you nothing about what the headphone was doing to start
/// with, and the sum of the two is the curve you will actually hear.
public struct FrequencyResponse: Hashable, Codable, Sendable {

    public struct Point: Hashable, Codable, Sendable {
        public var hz: Double
        public var db: Double
        public init(hz: Double, db: Double) { self.hz = hz; self.db = db }
    }

    public var name: String
    /// Sorted by frequency, ascending.
    public var points: [Point]

    public init(name: String, points: [Point]) {
        self.name = name
        self.points = points.sorted { $0.hz < $1.hz }
    }

    public var isEmpty: Bool { points.count < 2 }
    public var range: (low: Double, high: Double) {
        (points.first?.hz ?? 0, points.last?.hz ?? 0)
    }

    /// Magnitude at an arbitrary frequency, interpolated linearly in log-frequency.
    /// Outside the measured range the nearest endpoint is held, so a curve that
    /// stops at 10 kHz does not fall off a cliff.
    public func magnitudeDB(at hz: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if hz <= first.hz { return first.db }
        if hz >= last.hz { return last.db }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].hz <= hz { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        guard b.hz > a.hz, a.hz > 0 else { return a.db }
        let t = log10(hz / a.hz) / log10(b.hz / a.hz)
        return a.db + (b.db - a.db) * t
    }

    /// Shift the whole curve so the average over `low…high` sits at 0 dB.
    /// Measurement files carry arbitrary absolute levels, so they are only
    /// comparable once anchored somewhere.
    public func normalized(low: Double = 200, high: Double = 2_000) -> FrequencyResponse {
        // Integrate in log-frequency so file point density cannot change the level.
        let lo = max(low, range.low), hi = min(high, range.high)
        guard lo > 0, hi > lo else { return self }
        let knots = [lo] + points.filter { $0.hz > lo && $0.hz < hi }.map(\.hz) + [hi]
        var area = 0.0
        for (a, b) in zip(knots, knots.dropFirst()) {
            area += (magnitudeDB(at: a) + magnitudeDB(at: b)) * 0.5 * log(b / a)
        }
        let reference = area / log(hi / lo)
        return FrequencyResponse(name: name,
                                 points: points.map { Point(hz: $0.hz, db: $0.db - reference) })
    }

    /// Resample onto a log grid, which is what the plot and the sum both want.
    public func sampled(from low: Double = 20, to high: Double = 20_000, count: Int = 220) -> [Point] {
        let low = max(low, range.low), high = min(high, range.high)
        guard count > 1, low > 0, high > low else { return [] }
        return (0..<count).map { i in
            let hz = low * pow(high / low, Double(i) / Double(count - 1))
            return Point(hz: hz, db: magnitudeDB(at: hz))
        }
    }

    // MARK: - Parsing

    /// Accepts the common measurement exports: `freq,SPL` CSV, tab or
    /// semicolon separated, or whitespace separated, with or without a header
    /// row and with `#`, `//` or `*` comments. A third column (phase) is ignored.
    public static func parse(_ text: String, name: String) -> FrequencyResponse? {
        var points: [Point] = []
        var malformed = 0

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let first = line.unicodeScalars.first,
                  !"#/*;%".unicodeScalars.contains(first) || first == ";" else { continue }
            if line.hasPrefix("//") || line.hasPrefix("#") || line.hasPrefix("*") { continue }

            let fields = line
                .replacingOccurrences(of: ";", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .split(separator: " ")
                .filter { !$0.isEmpty }
            guard fields.count >= 2,
                  let hz = Double(fields[0]), let db = Double(fields[1]),
                  hz > 0, hz.isFinite, db.isFinite else {
                malformed += 1
                continue
            }
            points.append(Point(hz: hz, db: db))
        }

        guard points.count >= 8 else { return nil }
        _ = malformed
        // Average duplicate frequencies rather than letting them break interpolation.
        var merged: [Point] = []
        for p in points.sorted(by: { $0.hz < $1.hz }) {
            if let last = merged.last, abs(last.hz - p.hz) < 1e-9 {
                merged[merged.count - 1] = Point(hz: last.hz, db: (last.db + p.db) / 2)
            } else {
                merged.append(p)
            }
        }
        return FrequencyResponse(name: name, points: merged)
    }

    /// This curve minus another, sampled on the shared log grid. Used to read
    /// a measurement or a corrected result against a target.
    public func difference(from other: FrequencyResponse,
                           low: Double = 20, high: Double = 20_000,
                           count: Int = 220) -> [Point] {
        sampled(from: max(low, other.range.low), to: min(high, other.range.high), count: count).map {
            Point(hz: $0.hz, db: $0.db - other.magnitudeDB(at: $0.hz))
        }
    }

    /// Parse a file holding both ears: `frequency, left, right` per line.
    ///
    /// Returns `nil` unless the third column really is a second ear. Plenty of
    /// exports carry a third column that is phase, impedance or a smoothed
    /// trace, and reading one of those as a right channel produces a curve
    /// that looks plausible in a list and is nonsense on a plot. The column is
    /// accepted only when a header says so, or when the numbers themselves
    /// behave like a level curve.
    public static func parsePair(_ text: String, name: String)
        -> (left: FrequencyResponse, right: FrequencyResponse)? {
        var leftPoints: [Point] = [], rightPoints: [Point] = []
        var headerVerdict: Bool? = nil

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("//") || line.hasPrefix("#") || line.hasPrefix("*") { continue }
            let fields = line
                .replacingOccurrences(of: ";", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .split(separator: " ")
                .filter { !$0.isEmpty }
            guard fields.count >= 3 else { continue }

            // A non-numeric row is a header; let it decide.
            if Double(fields[0]) == nil {
                if headerVerdict == nil { headerVerdict = headerDescribesPair(fields) }
                continue
            }
            guard let hz = Double(fields[0]),
                  let l = Double(fields[1]),
                  let r = Double(fields[2]),
                  hz > 0, hz.isFinite, l.isFinite, r.isFinite else { continue }
            leftPoints.append(Point(hz: hz, db: l))
            rightPoints.append(Point(hz: hz, db: r))
        }

        guard leftPoints.count >= 8 else { return nil }
        if let headerVerdict { guard headerVerdict else { return nil } }
        else { guard looksLikeSecondEar(leftPoints, rightPoints) else { return nil } }

        return (FrequencyResponse(name: "\(name) L", points: leftPoints),
                FrequencyResponse(name: "\(name) R", points: rightPoints))
    }

    /// `frequency,left,right` yes; `frequency,raw,phase` no.
    static func headerDescribesPair(_ fields: [Substring]) -> Bool {
        let third = fields[2].lowercased().trimmingCharacters(in: .punctuationCharacters)
        let second = fields[1].lowercased().trimmingCharacters(in: .punctuationCharacters)
        let rightNames: Set<String> = ["r", "right", "right ear", "r channel", "rightear"]
        let leftNames: Set<String> = ["l", "left", "left ear", "l channel", "leftear"]
        let notALevel: Set<String> = ["phase", "deg", "degrees", "impedance", "ohms",
                                      "smoothed", "target", "error", "gain", "weight"]
        if notALevel.contains(where: { third.contains($0) }) { return false }
        if rightNames.contains(third) && leftNames.contains(second) { return true }
        if rightNames.contains(third) { return true }
        return false
    }

    /// Without a header, judge the third column on its behaviour. Two ears of
    /// one headphone track each other within a few dB and span a bounded
    /// range; phase sweeps ±180° and impedance is unbounded.
    static func looksLikeSecondEar(_ left: [Point], _ right: [Point]) -> Bool {
        guard left.count == right.count, !right.isEmpty else { return false }
        let values = right.map(\.db)
        guard let lo = values.min(), let hi = values.max() else { return false }
        // A level curve does not swing more than ~60 dB across the band.
        guard hi - lo <= 60 else { return false }
        // Nor does it live far outside the range measurements are published in.
        guard lo > -150, hi < 150 else { return false }
        // And the two ears should resemble each other.
        let meanAbsDiff = zip(left, right).reduce(0.0) { $0 + abs($1.0.db - $1.1.db) }
            / Double(left.count)
        return meanAbsDiff <= 15
    }

    /// The dB mean of several curves, resampled onto one log grid over the range
    /// they share. A single curve passes through unchanged, so callers can
    /// average whatever ears they happen to have.
    public static func average(_ curves: [FrequencyResponse], name: String,
                                low: Double = 20, high: Double = 20_000,
                                count: Int = 220) -> FrequencyResponse? {
        let present = curves.filter { !$0.isEmpty }
        guard let first = present.first else { return nil }
        guard present.count > 1 else { return first }
        // The intersection range: the endpoint-hold of magnitudeDB(at:) must
        // not stretch one ear's data over the other's gap.
        let lo = max(low, present.map { $0.range.low }.max() ?? low)
        let hi = min(high, present.map { $0.range.high }.min() ?? high)
        guard lo > 0, hi > lo else { return first }
        return FrequencyResponse(name: name, points: (0..<count).map { i in
            let hz = lo * pow(hi / lo, Double(i) / Double(count - 1))
            let db = present.reduce(0.0) { $0 + $1.magnitudeDB(at: hz) } / Double(present.count)
            return Point(hz: hz, db: db)
        })
    }

    /// The curve you will hear: the measurement plus everything the EQ does.
    public func corrected(by cascade: BiquadCascade, sampleRate: Double,
                          count: Int = 220) -> [Point] {
        // Keep measurement knots: flat EQ must preserve the original interpolated shape.
        let frequencies = Set(sampled(count: count).map(\.hz) + points.filter {
            $0.hz >= 20 && $0.hz <= 20_000
        }.map(\.hz)).sorted()
        return frequencies.map {
            Point(hz: $0, db: magnitudeDB(at: $0) + cascade.magnitudeDB(at: $0, sampleRate: sampleRate))
        }
    }
}
