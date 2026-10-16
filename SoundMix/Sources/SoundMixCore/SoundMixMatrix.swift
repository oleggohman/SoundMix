import Foundation

/// A full 16-in / 2-out downmix matrix in linear gain.
///
/// Unlike the original renderer — whose matrix is compiled in and gives every
/// left-side bed channel a coefficient of exactly 1.0 — every coefficient here
/// is data, so a recipe can attenuate surrounds and heights the way the common
/// downmix conventions do, and the resulting headroom can be computed exactly.
public struct SoundMixMatrix: Equatable, Sendable {
    /// `coefficients[bedChannel][0]` → left, `[1]` → right.
    public var coefficients: [[Double]]

    public init(coefficients: [[Double]]) {
        precondition(coefficients.count == BedChannel.count)
        self.coefficients = coefficients
    }

    public static let silent = SoundMixMatrix(
        coefficients: Array(repeating: [0, 0], count: BedChannel.count))

    public subscript(_ ch: BedChannel) -> (left: Double, right: Double) {
        get { (coefficients[ch.rawValue][0], coefficients[ch.rawValue][1]) }
        set { coefficients[ch.rawValue] = [newValue.left, newValue.right] }
    }

    /// Worst-case output peak for full-scale input on every channel at once
    /// (the L1 norm of each output row). Clipping is impossible below this.
    public var worstCasePeakGain: Double {
        var l = 0.0, r = 0.0
        for row in coefficients { l += abs(row[0]); r += abs(row[1]) }
        return max(l, r)
    }

    /// Gain for uncorrelated full-scale content (the L2 norm) — the realistic
    /// level change for real programme material.
    public var uncorrelatedGain: Double {
        var l = 0.0, r = 0.0
        for row in coefficients { l += row[0] * row[0]; r += row[1] * row[1] }
        return max(l, r).squareRoot()
    }

    public var worstCasePeakGainDB: Double { Self.dB(worstCasePeakGain) }
    public var uncorrelatedGainDB: Double { Self.dB(uncorrelatedGain) }

    /// Only the rows the layout actually feeds, so headroom reflects the source.
    public func restricted(to channels: [BedChannel]) -> SoundMixMatrix {
        var m = SoundMixMatrix.silent
        for ch in channels { m[ch] = self[ch] }
        return m
    }

    public func scaled(by gain: Double) -> SoundMixMatrix {
        SoundMixMatrix(coefficients: coefficients.map { [$0[0] * gain, $0[1] * gain] })
    }

    public func swappedOutputs() -> SoundMixMatrix {
        SoundMixMatrix(coefficients: coefficients.map { [$0[1], $0[0]] })
    }

    public static func dB(_ linear: Double) -> Double {
        linear > 1e-9 ? 20 * log10(linear) : -.infinity
    }
    public static func linear(_ db: Double) -> Double {
        db.isFinite ? pow(10, db / 20) : 0
    }
}

/// How the matrix output level is brought back under full scale.
public enum HeadroomMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// No automatic trim; the manual gain is the only level control.
    case none
    /// Trim by the matrix's L1 norm — mathematically cannot clip, costs the most level.
    case peakSafe
    /// Trim by the L2 norm — preserves perceived loudness for uncorrelated content.
    case powerPreserving

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none:            return "Manual only"
        case .peakSafe:        return "Peak-safe (L1)"
        case .powerPreserving: return "Power-preserving (L2)"
        }
    }

    public var explanation: String {
        switch self {
        case .none:
            return "No automatic trim. You set the level yourself, as the original app does with its −9.5 dB preamp default."
        case .peakSafe:
            return "Trims by the sum of the matrix coefficients, so a full-scale signal on every bed channel at once still cannot clip. The safest and the quietest."
        case .powerPreserving:
            return "Trims by the root-sum-square of the coefficients. Keeps perceived loudness close to the source for normal, uncorrelated material; brief peaks are caught by the limiter."
        }
    }
}

/// How the LFE channel reaches the stereo output.
public enum LFEMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, dry, lowPass
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .off:     return "Discard"
        case .dry:     return "Direct (no filter)"
        case .lowPass: return "Butterworth low-pass"
        }
    }
}

/// A human-editable description of a downmix, from which a matrix is generated.
public struct MatrixRecipe: Equatable, Codable, Sendable {
    public var name: String
    public var notes: String

    /// Per-group gain in dB applied to the channel's own side.
    public var groupGainDB: [String: Double]
    /// Per-group bleed to the opposite side in dB (`-inf` = none).
    public var groupBleedDB: [String: Double]
    /// Gain for centre-placed channels into both outputs.
    public var centerGainDB: Double
    public var lfeGainDB: Double
    public var lfeMode: LFEMode
    public var lfeCutoffHz: Double
    public var lfeFilterOrder: Int
    /// Explicit coefficient overrides, used by matrix-encoded recipes like Lt/Rt.
    public var explicit: [Int: [Double]]

    public init(name: String,
                notes: String = "",
                groupGainDB: [String: Double] = [:],
                groupBleedDB: [String: Double] = [:],
                centerGainDB: Double = -3.0103,
                lfeGainDB: Double = 0,
                lfeMode: LFEMode = .off,
                lfeCutoffHz: Double = 120,
                lfeFilterOrder: Int = 4,
                explicit: [Int: [Double]] = [:]) {
        self.name = name
        self.notes = notes
        self.groupGainDB = groupGainDB
        self.groupBleedDB = groupBleedDB
        self.centerGainDB = centerGainDB
        self.lfeGainDB = lfeGainDB
        self.lfeMode = lfeMode
        self.lfeCutoffHz = lfeCutoffHz
        self.lfeFilterOrder = lfeFilterOrder
        self.explicit = explicit
    }

    public func gainDB(for group: BedChannel.Group) -> Double {
        groupGainDB[group.rawValue] ?? 0
    }
    public func bleedDB(for group: BedChannel.Group) -> Double {
        groupBleedDB[group.rawValue] ?? -.infinity
    }

    /// Build the matrix. The LFE row carries only its gain — the low-pass and
    /// the dry-path delay are applied by the processor, not by the matrix.
    public func matrix() -> SoundMixMatrix {
        var m = SoundMixMatrix.silent
        for ch in BedChannel.allCases {
            if let override = explicit[ch.rawValue] {
                m[ch] = (override[0], override[1])
                continue
            }
            switch ch {
            case .lfe:
                let g = lfeMode == .off ? 0 : SoundMixMatrix.linear(lfeGainDB)
                m[ch] = (g, g)
            case .c:
                let g = SoundMixMatrix.linear(centerGainDB)
                m[ch] = (g, g)
            default:
                let same = SoundMixMatrix.linear(gainDB(for: ch.group))
                let opposite = SoundMixMatrix.linear(bleedDB(for: ch.group))
                switch ch.side {
                case .left:  m[ch] = (same, opposite)
                case .right: m[ch] = (opposite, same)
                case .none:  m[ch] = (same, same)
                }
            }
        }
        return m
    }
}

// MARK: - Built-in recipes

public extension MatrixRecipe {

    /// Byte-for-byte reproduction of the original renderer's compiled-in matrix,
    /// recovered from the shipped binary: every side channel at unity, centre at
    /// −3.01 dB, LFE at ×2.26464431 (+7.100 dB) into both outputs through a
    /// 4th-order 125 Hz Butterworth low-pass.
    static let parity = MatrixRecipe(
        name: "Original parity (ADC2 direct)",
        notes: "Exactly reproduces Downmix Renderer 0.0.0. Every surround and height channel sums at unity, so a full 9.1.6 bed can reach about +20 dB — use a trim or the limiter.",
        groupGainDB: [
            BedChannel.Group.front.rawValue: 0,
            BedChannel.Group.wide.rawValue: 0,
            BedChannel.Group.sideSurround.rawValue: 0,
            BedChannel.Group.rearSurround.rawValue: 0,
            BedChannel.Group.heightFront.rawValue: 0,
            BedChannel.Group.heightMiddle.rawValue: 0,
            BedChannel.Group.heightRear.rawValue: 0,
        ],
        centerGainDB: -3.0103,
        lfeGainDB: 7.1000,
        lfeMode: .lowPass,
        lfeCutoffHz: 125,
        lfeFilterOrder: 4)

    /// The conventional −3 dB fold: centre and surrounds at −3.01 dB, LFE discarded.
    static let reference = MatrixRecipe(
        name: "Reference fold (−3 dB)",
        notes: "The conventional stereo fold: centre and every surround at −3.01 dB, heights folded onto the floor layer at −3.01 dB, LFE discarded. Predictable level, no bass build-up.",
        groupGainDB: [
            BedChannel.Group.front.rawValue: 0,
            BedChannel.Group.wide.rawValue: -3.0103,
            BedChannel.Group.sideSurround.rawValue: -3.0103,
            BedChannel.Group.rearSurround.rawValue: -3.0103,
            BedChannel.Group.heightFront.rawValue: -3.0103,
            BedChannel.Group.heightMiddle.rawValue: -3.0103,
            BedChannel.Group.heightRear.rawValue: -3.0103,
        ],
        centerGainDB: -3.0103,
        lfeMode: .off,
        lfeCutoffHz: 120,
        lfeFilterOrder: 4)

    /// A depth-weighted fold: the further back or higher a channel sits, the more
    /// it is attenuated, which keeps the front image forward instead of flat.
    static let immersiveFold = MatrixRecipe(
        name: "Immersive fold (depth-weighted)",
        notes: "Attenuates by distance and height so the front image stays in front: wides −1.5, sides −3, rears −4.5, front heights −4.5, middle heights −6, rear heights −7.5 dB. A small opposite-side bleed on the surrounds keeps the rear field from collapsing hard into one speaker.",
        groupGainDB: [
            BedChannel.Group.front.rawValue: 0,
            BedChannel.Group.wide.rawValue: -1.5,
            BedChannel.Group.sideSurround.rawValue: -3.0,
            BedChannel.Group.rearSurround.rawValue: -4.5,
            BedChannel.Group.heightFront.rawValue: -4.5,
            BedChannel.Group.heightMiddle.rawValue: -6.0,
            BedChannel.Group.heightRear.rawValue: -7.5,
        ],
        groupBleedDB: [
            BedChannel.Group.sideSurround.rawValue: -15.0,
            BedChannel.Group.rearSurround.rawValue: -15.0,
            BedChannel.Group.heightMiddle.rawValue: -18.0,
            BedChannel.Group.heightRear.rawValue: -18.0,
        ],
        centerGainDB: -3.0103,
        lfeGainDB: 0,
        lfeMode: .lowPass,
        lfeCutoffHz: 100,
        lfeFilterOrder: 4)

    /// Matrix-encoded Lt/Rt, so a surround decoder downstream can unfold it again.
    static var ltRt: MatrixRecipe {
        let c = SoundMixMatrix.linear(-3.0103)
        let a = 0.8660254037844386      // sin 60°
        let b = 0.5                     // cos 60°
        var explicit: [Int: [Double]] = [
            BedChannel.l.rawValue: [1, 0],
            BedChannel.r.rawValue: [0, 1],
            BedChannel.c.rawValue: [c, c],
            BedChannel.lw.rawValue: [1, 0],
            BedChannel.rw.rawValue: [0, 1],
        ]
        // Surrounds and heights are matrix-encoded with the classic 90°-shifted
        // signs so a Pro Logic II style decoder can recover them.
        for ch in [BedChannel.ls, .lrs, .ltf, .ltm, .ltr] {
            explicit[ch.rawValue] = [-a, b]
        }
        for ch in [BedChannel.rs, .rrs, .rtf, .rtm, .rtr] {
            explicit[ch.rawValue] = [-b, a]
        }
        return MatrixRecipe(
            name: "Lt/Rt (matrix-encoded)",
            notes: "Classic matrix encode: surrounds and heights are mixed in with the ±0.866 / ±0.5 weights a Pro Logic II style decoder expects, so the surround field survives a stereo bounce. On plain stereo playback the surrounds sit slightly behind the front image.",
            centerGainDB: -3.0103,
            lfeMode: .off,
            explicit: explicit)
    }

    static let builtIns: [MatrixRecipe] = [reference, immersiveFold, parity, ltRt]
}
