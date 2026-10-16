import Foundation

/// Control-rate smoothing for the plot editor's live audition.
///
/// `SoundMixProcessor.apply` hands the render thread a whole new state. The
/// filter history is inherited, so the signal never restarts, but the
/// coefficients change in a single block — and a large change is heard as a
/// click. The alternatives were a crossfade between two chains or a coefficient
/// ramp, both of which mean extra work inside the one render path that every
/// fold, the limiter and the offline renderer share; neither is worth
/// destabilising that path for an editing convenience.
///
/// So the smoothing happens on the control thread instead: the audible EQ walks
/// toward the draft in bounded steps, one per coalescing tick, and the render
/// thread keeps doing exactly what it did before. Dragging at a human speed is
/// therefore exact — each tick's change is far below the cap — while a flick, a
/// typed value or a Cancel after a big edit arrives over a few hundred
/// milliseconds instead of clicking.
///
/// Structural edits cannot be interpolated: adding, deleting, retyping or
/// switching off a band changes what there is to interpolate between, so those
/// snap. They are also the edits that do not produce a loud step, because a
/// disabled or added band starts from no contribution.
public enum PEQAudition {

    /// One tick's worth of change. At the editor's 25 Hz tick these are
    /// 37.5 dB and 6.25 octaves per second — faster than anybody drags
    /// deliberately, slow enough that one step is not a click.
    public static let maxGainStepDB = 1.5
    public static let maxFrequencyStepOctaves = 0.25

    /// The three EQ stages the processor renders, in physical-ear terms:
    /// `left` is what the left ear hears, whether or not the outputs are swapped.
    public struct Stages: Equatable, Sendable {
        public var global: PEQProfile
        public var left: PEQProfile
        public var right: PEQProfile

        public init(global: PEQProfile = .flat, left: PEQProfile = .flat, right: PEQProfile = .flat) {
            self.global = global
            self.left = left
            self.right = right
        }

        /// One tick toward `target`, stage by stage.
        public func stepped(toward target: Stages) -> Stages {
            Stages(global: PEQAudition.step(global, toward: target.global),
                   left: PEQAudition.step(left, toward: target.left),
                   right: PEQAudition.step(right, toward: target.right))
        }
    }

    /// One tick of one stage. Returns `target` exactly once it is within a
    /// single step, so convergence is an equality test rather than a tolerance.
    public static func step(_ current: PEQProfile, toward target: PEQProfile,
                            maxGainStepDB: Double = PEQAudition.maxGainStepDB,
                            maxFrequencyStepOctaves: Double = PEQAudition.maxFrequencyStepOctaves) -> PEQProfile {
        guard isInterpolatable(current, target) else { return target }
        // Start from the target so kinds, enables and count are already right.
        var next = target
        next.preampDB = approach(current.preampDB, target.preampDB, maxGainStepDB)
        for i in next.filters.indices {
            next.filters[i].gainDB = approach(current.filters[i].gainDB,
                                              target.filters[i].gainDB, maxGainStepDB)
            next.filters[i].frequency = approachRatio(current.filters[i].frequency,
                                                      target.filters[i].frequency, maxFrequencyStepOctaves)
            next.filters[i].q = approachRatio(current.filters[i].q,
                                              target.filters[i].q, maxFrequencyStepOctaves)
        }
        return next
    }

    /// Two profiles describe the same filters and differ only in their values.
    private static func isInterpolatable(_ a: PEQProfile, _ b: PEQProfile) -> Bool {
        guard a.filters.count == b.filters.count else { return false }
        for (x, y) in zip(a.filters, b.filters) where x.kind != y.kind || x.enabled != y.enabled {
            return false
        }
        return true
    }

    private static func approach(_ from: Double, _ to: Double, _ maxStep: Double) -> Double {
        guard from.isFinite, to.isFinite, maxStep > 0 else { return to }
        let delta = to - from
        guard abs(delta) > maxStep else { return to }
        return from + (delta < 0 ? -maxStep : maxStep)
    }

    /// The same, in octaves, for the quantities the ear hears logarithmically.
    private static func approachRatio(_ from: Double, _ to: Double, _ maxOctaves: Double) -> Double {
        guard from.isFinite, to.isFinite, from > 0, to > 0, maxOctaves > 0 else { return to }
        let delta = log2(to / from)
        guard abs(delta) > maxOctaves else { return to }
        return from * pow(2, delta < 0 ? -maxOctaves : maxOctaves)
    }
}
