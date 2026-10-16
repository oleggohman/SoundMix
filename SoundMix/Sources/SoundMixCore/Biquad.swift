import Foundation

/// Direct-form-II transposed biquad section with `Double` state.
///
/// Coefficients are stored already normalised by `a0`.
public struct Biquad: Sendable, Equatable {
    public var b0: Double = 1, b1: Double = 0, b2: Double = 0
    public var a1: Double = 0, a2: Double = 0

    public init() {}
    public init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let n = a0 == 0 ? 1 : a0
        self.b0 = b0 / n; self.b1 = b1 / n; self.b2 = b2 / n
        self.a1 = a1 / n; self.a2 = a2 / n
    }

    public static let identity = Biquad()

    /// Complex frequency response at `frequency` Hz for `sampleRate` Hz.
    public func response(at frequency: Double, sampleRate: Double) -> (re: Double, im: Double) {
        let w = 2 * Double.pi * frequency / sampleRate
        let cw = cos(w), sw = sin(w)
        let c2w = cos(2 * w), s2w = sin(2 * w)
        let nr = b0 + b1 * cw + b2 * c2w
        let ni = -(b1 * sw + b2 * s2w)
        let dr = 1 + a1 * cw + a2 * c2w
        let di = -(a1 * sw + a2 * s2w)
        let den = dr * dr + di * di
        guard den > 0 else { return (0, 0) }
        return ((nr * dr + ni * di) / den, (ni * dr - nr * di) / den)
    }

    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let (re, im) = response(at: frequency, sampleRate: sampleRate)
        let m = (re * re + im * im).squareRoot()
        return m > 0 ? 20 * log10(m) : -200
    }

    /// Group delay in samples at `frequency` Hz.
    public func groupDelay(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func tau(_ c: [Double]) -> Double {
            // Re{ (Σ k·c_k·z^-k) / (Σ c_k·z^-k) } with z = e^{jw}
            var nr = 0.0, ni = 0.0, dr = 0.0, di = 0.0
            for (k, ck) in c.enumerated() {
                let ang = -Double(k) * w
                let cr = ck * cos(ang), ci = ck * sin(ang)
                dr += cr; di += ci
                nr += Double(k) * cr; ni += Double(k) * ci
            }
            let den = dr * dr + di * di
            guard den > 1e-300 else { return 0 }
            return (nr * dr + ni * di) / den
        }
        return tau([b0, b1, b2]) - tau([1, a1, a2])
    }
}

/// Mutable per-stream state for one biquad section.
public struct BiquadState: Sendable {
    public var z1: Double = 0, z2: Double = 0
    public init() {}
    public mutating func reset() { z1 = 0; z2 = 0 }
}

/// A cascade of biquad sections plus a linear pre-gain.
public struct BiquadCascade: Sendable, Equatable {
    public var sections: [Biquad]
    public var preGain: Double

    public init(sections: [Biquad] = [], preGain: Double = 1.0) {
        self.sections = sections
        self.preGain = preGain
    }

    public var isTransparent: Bool { sections.isEmpty && preGain == 1.0 }

    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        var db = preGain > 0 ? 20 * log10(preGain) : -200
        for s in sections { db += s.magnitudeDB(at: frequency, sampleRate: sampleRate) }
        return db
    }

    public func groupDelay(at frequency: Double, sampleRate: Double) -> Double {
        sections.reduce(0) { $0 + $1.groupDelay(at: frequency, sampleRate: sampleRate) }
    }
}

/// Runtime state for a cascade; kept separate so coefficients stay value types.
public final class BiquadChain {
    public private(set) var cascade: BiquadCascade
    private var state: [BiquadState]

    public init(_ cascade: BiquadCascade = BiquadCascade()) {
        self.cascade = cascade
        self.state = Array(repeating: BiquadState(), count: cascade.sections.count)
    }

    func inheritHistory(from previous: BiquadChain) {
        guard state.count == previous.state.count else { return }
        for i in state.indices { state[i] = previous.state[i] }
    }

    /// Replace coefficients. State is preserved where the section count matches
    /// so that live edits do not click.
    public func update(_ newCascade: BiquadCascade) {
        if newCascade.sections.count != state.count {
            state = Array(repeating: BiquadState(), count: newCascade.sections.count)
        }
        cascade = newCascade
    }

    public func reset() {
        for i in state.indices { state[i].reset() }
    }

    @inline(__always)
    public func process(_ input: Double) -> Double {
        var x = input * cascade.preGain
        for i in cascade.sections.indices {
            let s = cascade.sections[i]
            let y = s.b0 * x + state[i].z1
            state[i].z1 = s.b1 * x - s.a1 * y + state[i].z2
            state[i].z2 = s.b2 * x - s.a2 * y
            x = y
        }
        return x
    }
}

// MARK: - Designers

public enum BiquadDesign {

    /// RBJ cookbook peaking EQ.
    public static func peaking(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 1e-4))
        return Biquad(b0: 1 + alpha * a, b1: -2 * cos(w0), b2: 1 - alpha * a,
                      a0: 1 + alpha / a, a1: -2 * cos(w0), a2: 1 - alpha / a)
    }

    /// RBJ cookbook low shelf. `slope` is the cookbook `S` (1.0 = steepest without peaking).
    public static func lowShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 1e-4))
        let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
        return Biquad(
            b0: a * ((a + 1) - (a - 1) * cw + twoSqrtAAlpha),
            b1: 2 * a * ((a - 1) - (a + 1) * cw),
            b2: a * ((a + 1) - (a - 1) * cw - twoSqrtAAlpha),
            a0: (a + 1) + (a - 1) * cw + twoSqrtAAlpha,
            a1: -2 * ((a - 1) + (a + 1) * cw),
            a2: (a + 1) + (a - 1) * cw - twoSqrtAAlpha)
    }

    /// RBJ cookbook high shelf.
    public static func highShelf(frequency: Double, q: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 1e-4))
        let twoSqrtAAlpha = 2 * a.squareRoot() * alpha
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cw + twoSqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cw),
            b2: a * ((a + 1) + (a - 1) * cw - twoSqrtAAlpha),
            a0: (a + 1) - (a - 1) * cw + twoSqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cw),
            a2: (a + 1) - (a - 1) * cw - twoSqrtAAlpha)
    }

    /// Second-order low-pass with explicit Q (one Butterworth section).
    public static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 1e-4))
        return Biquad(b0: (1 - cw) / 2, b1: 1 - cw, b2: (1 - cw) / 2,
                      a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// One-pole low-pass, used as the odd section of an odd-order Butterworth.
    public static func onePoleLowPass(frequency: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let k = tan(w0 / 2)
        let norm = 1 / (k + 1)
        return Biquad(b0: k * norm, b1: k * norm, b2: 0,
                      a0: 1, a1: (k - 1) * norm, a2: 0)
    }

    /// Butterworth low-pass of arbitrary `order` (1…16), as a cascade of biquads.
    ///
    /// Pole Qs come from the standard Butterworth pole placement
    /// `Q_k = 1 / (2·cos(π·(2k+1) / (2n)))`, with a leading one-pole section
    /// when the order is odd. A 4th-order cascade gives the 24 dB/octave slope
    /// the original renderer hard-codes at 125 Hz.
    public static func butterworthLowPass(frequency: Double, order: Int, sampleRate: Double) -> BiquadCascade {
        let n = max(1, min(order, 16))
        var sections: [Biquad] = []
        if n % 2 == 1 {
            sections.append(onePoleLowPass(frequency: frequency, sampleRate: sampleRate))
        }
        let pairs = n / 2
        for k in 0..<pairs {
            // Pole angles for the upper half-plane, skipping the real pole when odd.
            let theta = Double.pi * (2 * Double(k) + 1) / (2 * Double(n))
            let q = 1 / (2 * cos(n % 2 == 1 ? Double.pi * (2 * Double(k) + 2) / (2 * Double(n)) : theta))
            sections.append(lowPass(frequency: frequency, q: abs(q), sampleRate: sampleRate))
        }
        return BiquadCascade(sections: sections)
    }

    /// Second-order high-pass with explicit Q, the mirror of `lowPass`.
    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * clampFrequency(frequency, sampleRate) / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 1e-4))
        return Biquad(b0: (1 + cw) / 2, b1: -(1 + cw), b2: (1 + cw) / 2,
                      a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// A 4th-order Linkwitz-Riley crossover pair: two cascaded Butterworth
    /// sections per leg. The two legs sum to an all-pass, so splitting a signal
    /// with this pair and adding the halves back leaves the magnitude flat —
    /// which is what the binaural bass path relies on.
    public static func linkwitzRiley4(frequency: Double, sampleRate: Double)
        -> (low: BiquadCascade, high: BiquadCascade) {
        let q = 0.5.squareRoot()
        let lp = lowPass(frequency: frequency, q: q, sampleRate: sampleRate)
        let hp = highPass(frequency: frequency, q: q, sampleRate: sampleRate)
        return (BiquadCascade(sections: [lp, lp]), BiquadCascade(sections: [hp, hp]))
    }

    @inline(__always)
    static func clampFrequency(_ f: Double, _ sampleRate: Double) -> Double {
        min(max(f, 1.0), sampleRate * 0.49)
    }
}
