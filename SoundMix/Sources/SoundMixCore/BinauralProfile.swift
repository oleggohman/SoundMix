import Foundation

/// How the LFE channel is treated, independently of which fold is in use.
///
/// Both an amplitude `MatrixRecipe` and a `BinauralProfile` carry one of these,
/// so the processor can ask for the LFE settings without knowing which fold it
/// is rendering.
public struct LFESettings: Equatable, Codable, Sendable {
    public var mode: LFEMode
    public var gainDB: Double
    public var cutoffHz: Double
    public var filterOrder: Int

    public init(mode: LFEMode = .off, gainDB: Double = 0,
                cutoffHz: Double = 120, filterOrder: Int = 4) {
        self.mode = mode
        self.gainDB = gainDB
        self.cutoffHz = cutoffHz
        self.filterOrder = filterOrder
    }
}

public extension MatrixRecipe {
    var lfeSettings: LFESettings {
        LFESettings(mode: lfeMode, gainDB: lfeGainDB,
                    cutoffHz: lfeCutoffHz, filterOrder: lfeFilterOrder)
    }
}

/// Which filter bank the binaural fold is built from.
///
/// Both models are synthesised from first principles at the device sample rate.
/// Nothing is measured and no dataset ships with the application, which keeps the
/// binary small and the licensing clean; a measured SOFA set can be loaded into
/// the same engine later without touching the renderer.
public enum BinauralModel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Woodworth inter-aural delay plus the Brown-Duda spherical head shadow,
    /// with coarse elevation and front/back cues layered on top.
    case sphericalHead
    /// Plain headphone crossfeed: each ear hears the opposite side delayed,
    /// attenuated and rolled off, with no head model at all.
    case crossfeed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sphericalHead: return "Virtual speakers (spherical head)"
        case .crossfeed:     return "Headphone crossfeed"
        }
    }

    public var explanation: String {
        switch self {
        case .sphericalHead:
            return "Places every bed channel at its real loudspeaker angle and filters it with a synthesised head-related response: inter-aural delay from the Woodworth model, head shadowing from the Brown-Duda sphere, plus a coarse elevation notch and a rear roll-off. Headphones only."
        case .crossfeed:
            return "The cheap option: no head model, just a short delayed and rolled-off copy of each side fed to the opposite ear. Relieves the hard-panned, inside-the-head quality of a stereo fold without changing timbre much. Headphones only."
        }
    }
}

/// A human-editable description of a binaural fold, from which a filter bank is
/// generated — the counterpart to `MatrixRecipe` for the HRTF path.
public struct BinauralProfile: Equatable, Codable, Sendable {
    public var name: String
    public var notes: String
    public var model: BinauralModel

    /// Head radius in centimetres. Sets both the inter-aural delay and the
    /// corner frequency of the head shadow (omega = c / a).
    public var headRadiusCM: Double
    /// Below this the signal is folded to both ears equally, because direction
    /// is not carried by head-related cues down there and per-ear filtering of
    /// the bass only invites comb filtering. `0` switches the split off.
    public var bassCrossoverHz: Double
    /// How much high-frequency energy a source directly behind the listener
    /// loses. The spherical model alone is front/back ambiguous; this is the
    /// cue that resolves it. `0` switches it off.
    public var rearDampingDB: Double
    /// Depth of the pinna notch whose frequency rises with elevation — a coarse
    /// up/down cue, not a measured pinna. `0` switches it off.
    public var elevationCueDB: Double

    /// Crossfeed model only: how late the opposite ear hears the signal.
    public var crossfeedDelayUS: Double
    /// Crossfeed model only: level of the opposite-ear copy.
    public var crossfeedLevelDB: Double
    /// Crossfeed model only: corner of the one-pole roll-off on that copy.
    public var crossfeedCutoffHz: Double

    public var lfe: LFESettings

    public init(name: String,
                notes: String = "",
                model: BinauralModel = .sphericalHead,
                headRadiusCM: Double = 8.75,
                bassCrossoverHz: Double = 150,
                rearDampingDB: Double = -3.5,
                elevationCueDB: Double = -8,
                crossfeedDelayUS: Double = 270,
                crossfeedLevelDB: Double = -4.5,
                crossfeedCutoffHz: Double = 700,
                lfe: LFESettings = LFESettings(mode: .lowPass, gainDB: 0,
                                               cutoffHz: 120, filterOrder: 4)) {
        self.name = name
        self.notes = notes
        self.model = model
        self.headRadiusCM = headRadiusCM
        self.bassCrossoverHz = bassCrossoverHz
        self.rearDampingDB = rearDampingDB
        self.elevationCueDB = elevationCueDB
        self.crossfeedDelayUS = crossfeedDelayUS
        self.crossfeedLevelDB = crossfeedLevelDB
        self.crossfeedCutoffHz = crossfeedCutoffHz
        self.lfe = lfe
    }

    /// Head radius in metres, clamped to a physically sensible range.
    public var headRadiusMeters: Double { min(max(headRadiusCM, 5), 12) / 100 }

    public static let speedOfSound = 343.0

    // MARK: - Built-ins

    public static let virtualSpeakers = BinauralProfile(
        name: "Virtual speakers (spherical head)",
        notes: "Every bed channel is auditioned from its own loudspeaker angle through a synthesised head response. Bass below the crossover stays centred, the LFE keeps its own filter. For headphones only — it will sound wrong on speakers.",
        model: .sphericalHead)

    public static let wideHead = BinauralProfile(
        name: "Virtual speakers (wide head)",
        notes: "The same virtual-speaker fold with a 9.5 cm head radius and a deeper rear roll-off: a longer inter-aural delay and a stronger front/back cue, which some listeners hear as more external and others as overly wide.",
        model: .sphericalHead,
        headRadiusCM: 9.5,
        rearDampingDB: -5.0,
        elevationCueDB: -9)

    public static let crossfeedOnly = BinauralProfile(
        name: "Headphone crossfeed",
        notes: "No head model: each ear simply hears a short, rolled-off copy of the opposite side. Cheap, almost colour-free, and it only loosens the hard-panned stereo image rather than placing the channels around you.",
        model: .crossfeed,
        bassCrossoverHz: 0,
        rearDampingDB: 0,
        elevationCueDB: 0)

    public static let builtIns: [BinauralProfile] = [virtualSpeakers, wideHead, crossfeedOnly]
}
