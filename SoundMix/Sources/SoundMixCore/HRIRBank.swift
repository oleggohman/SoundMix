import Foundation

/// Where a bed channel sits around the listener.
///
/// Azimuth is degrees counter-clockwise seen from above: 0 is straight ahead,
/// +90 is the listener's left, 180 is directly behind. Elevation is degrees
/// above the ear plane.
public struct SpeakerDirection: Equatable, Sendable {
    public var azimuthDeg: Double
    public var elevationDeg: Double

    public init(azimuthDeg: Double, elevationDeg: Double = 0) {
        self.azimuthDeg = azimuthDeg
        self.elevationDeg = elevationDeg
    }

    /// Unit vector in a right-handed frame: x forward, y left, z up.
    public var unitVector: (x: Double, y: Double, z: Double) {
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        return (cos(el) * cos(az), cos(el) * sin(az), sin(el))
    }
}

public extension BedChannel {
    /// The loudspeaker angle the binaural fold places this bed slot at, taken
    /// from the common 9.1.6 layout the bed is defined in.
    var direction: SpeakerDirection {
        switch self {
        case .l:   return SpeakerDirection(azimuthDeg: 30)
        case .r:   return SpeakerDirection(azimuthDeg: -30)
        case .c:   return SpeakerDirection(azimuthDeg: 0)
        case .lfe: return SpeakerDirection(azimuthDeg: 0)
        case .lw:  return SpeakerDirection(azimuthDeg: 60)
        case .rw:  return SpeakerDirection(azimuthDeg: -60)
        case .ls:  return SpeakerDirection(azimuthDeg: 90)
        case .rs:  return SpeakerDirection(azimuthDeg: -90)
        case .lrs: return SpeakerDirection(azimuthDeg: 135)
        case .rrs: return SpeakerDirection(azimuthDeg: -135)
        case .ltf: return SpeakerDirection(azimuthDeg: 45, elevationDeg: 35)
        case .rtf: return SpeakerDirection(azimuthDeg: -45, elevationDeg: 35)
        case .ltm: return SpeakerDirection(azimuthDeg: 90, elevationDeg: 45)
        case .rtm: return SpeakerDirection(azimuthDeg: -90, elevationDeg: 45)
        case .ltr: return SpeakerDirection(azimuthDeg: 135, elevationDeg: 35)
        case .rtr: return SpeakerDirection(azimuthDeg: -135, elevationDeg: 35)
        }
    }

    /// The bed slot mirrored across the median plane; centre slots map to
    /// themselves. The binaural engine folds these pairs together.
    var mirrored: BedChannel {
        switch self {
        case .l: return .r;     case .r: return .l
        case .lw: return .rw;   case .rw: return .lw
        case .ls: return .rs;   case .rs: return .ls
        case .lrs: return .rrs; case .rrs: return .lrs
        case .ltf: return .rtf; case .rtf: return .ltf
        case .ltm: return .rtm; case .rtm: return .ltm
        case .ltr: return .rtr; case .rtr: return .ltr
        case .c: return .c;     case .lfe: return .lfe
        }
    }
}

/// A 16-in / 2-out bank of finite impulse responses — the binaural counterpart
/// of `SoundMixMatrix`, where every coefficient is a whole filter rather than a
/// single gain.
///
/// The LFE row is deliberately empty: low frequencies carry no head-related
/// direction cues, so the LFE keeps its own filter and gain in the processor
/// exactly as it does in the amplitude path.
public struct HRIRBank: Sendable, Equatable {
    public let model: BinauralModel
    public let sampleRate: Double
    public let tapCount: Int
    /// Flat storage, indexed `(channel * 2 + ear) * tapCount + n`; ear 0 is left.
    public let taps: [Double]
    /// What each channel contributes to the non-directional bass path, set to
    /// the mean of its two ears' DC gains so the crossover sums back to flat.
    public let bassWeights: [Double]
    /// Bulk delay of the filter bank in samples, used to time-align the bass
    /// path with the convolved path.
    public let referenceDelaySamples: Int

    public static let leftEar = 0
    public static let rightEar = 1

    init(model: BinauralModel, sampleRate: Double, tapCount: Int,
         taps: [Double], bassWeights: [Double], referenceDelaySamples: Int) {
        self.model = model
        self.sampleRate = sampleRate
        self.tapCount = tapCount
        self.taps = taps
        self.bassWeights = bassWeights
        self.referenceDelaySamples = referenceDelaySamples
    }

    public func taps(_ ch: BedChannel, ear: Int) -> ArraySlice<Double> {
        let start = (ch.rawValue * 2 + ear) * tapCount
        return taps[start..<(start + tapCount)]
    }

    /// DC gain of one impulse response — the sum of its taps.
    public func dcGain(_ ch: BedChannel, ear: Int) -> Double {
        taps(ch, ear: ear).reduce(0, +)
    }

    /// Energy-weighted centroid of an impulse response, in samples. Used both
    /// to align the bass path and to report inter-aural delay.
    public func centroidDelaySamples(_ ch: BedChannel, ear: Int) -> Double {
        var weighted = 0.0, total = 0.0
        for (n, h) in taps(ch, ear: ear).enumerated() {
            let a = abs(h)
            weighted += Double(n) * a
            total += a
        }
        return total > 0 ? weighted / total : 0
    }

    /// Inter-aural time difference in microseconds, positive when the left ear
    /// hears the channel first.
    public func itdMicroseconds(_ ch: BedChannel) -> Double {
        (centroidDelaySamples(ch, ear: Self.rightEar) - centroidDelaySamples(ch, ear: Self.leftEar))
            / sampleRate * 1e6
    }

    /// Level the channel reaches each ear at, in dB, ignoring timing.
    public func gainDB(_ ch: BedChannel, ear: Int) -> Double {
        SoundMixMatrix.dB(taps(ch, ear: ear).reduce(0) { $0 + $1 * $1 }.squareRoot())
    }

    /// Worst-case output peak for full-scale input on every listed channel at
    /// once: the sum of absolute taps, which is the FIR analogue of the
    /// matrix's L1 norm. Clipping is impossible below this.
    public func worstCasePeakGain(for channels: [BedChannel]) -> Double {
        var l = 0.0, r = 0.0
        for ch in channels where ch != .lfe {
            l += taps(ch, ear: Self.leftEar).reduce(0) { $0 + abs($1) }
            r += taps(ch, ear: Self.rightEar).reduce(0) { $0 + abs($1) }
        }
        return max(l, r)
    }

    /// Gain for uncorrelated full-scale content: the root of the summed tap
    /// energy, the FIR analogue of the matrix's L2 norm.
    public func uncorrelatedGain(for channels: [BedChannel]) -> Double {
        var l = 0.0, r = 0.0
        for ch in channels where ch != .lfe {
            l += taps(ch, ear: Self.leftEar).reduce(0) { $0 + $1 * $1 }
            r += taps(ch, ear: Self.rightEar).reduce(0) { $0 + $1 * $1 }
        }
        return max(l, r).squareRoot()
    }

    public func scaled(by gain: Double) -> HRIRBank {
        HRIRBank(model: model, sampleRate: sampleRate, tapCount: tapCount,
                 taps: taps.map { $0 * gain },
                 bassWeights: bassWeights.map { $0 * gain },
                 referenceDelaySamples: referenceDelaySamples)
    }

    /// True when every mirrored pair is an exact mirror of the other — the
    /// property the two-convolution fold relies on.
    public func isMirrorSymmetric(tolerance: Double = 1e-12) -> Bool {
        for ch in BedChannel.allCases where ch != .lfe {
            let m = ch.mirrored
            let a = Array(taps(ch, ear: Self.leftEar)), b = Array(taps(m, ear: Self.rightEar))
            let c = Array(taps(ch, ear: Self.rightEar)), d = Array(taps(m, ear: Self.leftEar))
            for n in 0..<tapCount {
                if abs(a[n] - b[n]) > tolerance || abs(c[n] - d[n]) > tolerance { return false }
            }
        }
        return true
    }

    // MARK: - Synthesis

    /// Half-width of the fractional-delay kernel, in samples.
    static let kernelHalfWidth = 16

    public static func tapCount(for sampleRate: Double, profile: BinauralProfile) -> Int {
        let a = profile.headRadiusMeters
        let maxDelay = (a / BinauralProfile.speedOfSound) * (1 + Double.pi / 2)
        let crossfeed = profile.crossfeedDelayUS / 1e6
        let span = max(maxDelay, crossfeed) + 0.0012      // + filter tail
        let raw = Int((span * sampleRate).rounded(.up)) + 2 * kernelHalfWidth
        return max(64, (raw + 7) / 8 * 8)
    }

    /// Build the bank for a profile at a given rate. Control-thread work only —
    /// the result is immutable and is handed to the renderer as data.
    public static func generate(profile: BinauralProfile, sampleRate: Double) -> HRIRBank {
        let n = tapCount(for: sampleRate, profile: profile)
        var taps = [Double](repeating: 0, count: BedChannel.count * 2 * n)
        var weights = [Double](repeating: 0, count: BedChannel.count)

        for ch in BedChannel.allCases where ch != .lfe {
            var dc = 0.0
            for ear in [leftEar, rightEar] {
                let h: [Double]
                switch profile.model {
                case .sphericalHead: h = sphericalHeadResponse(ch, ear: ear, profile: profile,
                                                               sampleRate: sampleRate, tapCount: n)
                case .crossfeed:     h = crossfeedResponse(ch, ear: ear, profile: profile,
                                                           sampleRate: sampleRate, tapCount: n)
                }
                let base = (ch.rawValue * 2 + ear) * n
                for i in 0..<n { taps[base + i] = h[i] }
                dc += h.reduce(0, +)
            }
            weights[ch.rawValue] = dc / 2
        }

        let bank = HRIRBank(model: profile.model, sampleRate: sampleRate, tapCount: n,
                            taps: taps, bassWeights: weights, referenceDelaySamples: 0)
        let reference = Int(bank.centroidDelaySamples(.c, ear: leftEar).rounded())
        return HRIRBank(model: profile.model, sampleRate: sampleRate, tapCount: n,
                        taps: taps, bassWeights: weights,
                        referenceDelaySamples: max(0, reference))
    }

    /// Woodworth delay + Brown-Duda head shadow, with the elevation notch and
    /// the rear roll-off that make the spherical model usable.
    private static func sphericalHeadResponse(_ ch: BedChannel, ear: Int,
                                              profile: BinauralProfile,
                                              sampleRate: Double, tapCount: Int) -> [Double] {
        let a = profile.headRadiusMeters
        let c = BinauralProfile.speedOfSound
        let source = ch.direction.unitVector
        let earY = ear == leftEar ? 1.0 : -1.0
        // Angle between the source and the ear's outward normal.
        let cosTheta = min(max(source.y * earY, -1), 1)
        let theta = acos(cosTheta)

        // Woodworth and Schlosberg: the near ear hears it early, the far ear
        // late by the extra distance around the sphere.
        let tau = theta < .pi / 2 ? -(a / c) * cos(theta) : (a / c) * (theta - .pi / 2)
        let delaySamples = (tau + a / c) * sampleRate

        var h = fractionalDelayImpulse(delay: delaySamples, tapCount: tapCount)

        var sections = [headShadow(theta: theta, headRadius: a, sampleRate: sampleRate)]
        if profile.elevationCueDB != 0 {
            // The pinna notch climbs with elevation; coarse, but it is the cue
            // that stops the height channels collapsing into the ear plane.
            let f = 6000 + 45 * ch.direction.elevationDeg
            if f < sampleRate * 0.45 {
                sections.append(BiquadDesign.peaking(frequency: f, q: 2,
                                                     gainDB: profile.elevationCueDB,
                                                     sampleRate: sampleRate))
            }
        }
        if profile.rearDampingDB != 0, source.x < 0 {
            sections.append(BiquadDesign.highShelf(frequency: 4000, q: 0.7,
                                                   gainDB: profile.rearDampingDB * -source.x,
                                                   sampleRate: sampleRate))
        }

        let chain = BiquadChain(BiquadCascade(sections: sections))
        for i in 0..<tapCount { h[i] = chain.process(h[i]) }
        return h
    }

    /// No head model: the near ear gets the signal untouched, the far ear a
    /// delayed, attenuated and rolled-off copy.
    private static func crossfeedResponse(_ ch: BedChannel, ear: Int,
                                          profile: BinauralProfile,
                                          sampleRate: Double, tapCount: Int) -> [Double] {
        let ipsilateral: Bool
        switch ch.side {
        case .left:  ipsilateral = ear == leftEar
        case .right: ipsilateral = ear == rightEar
        case .none:  ipsilateral = true          // centre reaches both ears alike
        }
        if ipsilateral { return fractionalDelayImpulse(delay: 0, tapCount: tapCount) }

        let delay = profile.crossfeedDelayUS / 1e6 * sampleRate
        var h = fractionalDelayImpulse(delay: delay, tapCount: tapCount)
        let level = SoundMixMatrix.linear(profile.crossfeedLevelDB)
        let chain = BiquadChain(BiquadCascade(sections: [
            BiquadDesign.onePoleLowPass(frequency: profile.crossfeedCutoffHz,
                                        sampleRate: sampleRate)]))
        for i in 0..<tapCount { h[i] = chain.process(h[i]) * level }
        return h
    }

    /// Brown and Duda's single pole/zero spherical head shadow. `alpha` runs
    /// from 2 at the near ear to 0.1 in the acoustic shadow at 150 degrees;
    /// the DC gain is exactly 1 at every angle, which is what lets the bass
    /// crossover sum back to flat.
    static func headShadow(theta: Double, headRadius: Double, sampleRate: Double) -> Biquad {
        let omega0 = BinauralProfile.speedOfSound / headRadius
        let k = sampleRate / omega0
        let alphaMin = 0.1, thetaMin = 150.0
        let thetaDeg = theta * 180 / .pi
        let alpha = (1 + alphaMin / 2) + (1 - alphaMin / 2) * cos(thetaDeg / thetaMin * .pi)
        return Biquad(b0: 1 + alpha * k, b1: 1 - alpha * k, b2: 0,
                      a0: 1 + k, a1: 1 - k, a2: 0)
    }

    /// A Blackman-windowed sinc, normalised to unit DC gain, centred
    /// `kernelHalfWidth + delay` samples into the response.
    static func fractionalDelayImpulse(delay: Double, tapCount: Int) -> [Double] {
        var h = [Double](repeating: 0, count: tapCount)
        let m = Double(kernelHalfWidth)
        let centre = m + delay
        let first = max(0, Int((centre - m).rounded(.down)))
        let last = min(tapCount - 1, Int((centre + m).rounded(.up)))
        guard first <= last else { return h }
        var sum = 0.0
        for i in first...last {
            let x = Double(i) - centre
            if abs(x) > m { continue }
            let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
            let w = 0.42 + 0.5 * cos(.pi * x / m) + 0.08 * cos(2 * .pi * x / m)
            h[i] = sinc * w
            sum += h[i]
        }
        if sum != 0 { for i in first...last { h[i] /= sum } }
        return h
    }

    // MARK: - Cache

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [(profile: BinauralProfile, rate: Double, bank: HRIRBank)] = []

    /// Generation is cheap but not free, and the interface asks for the bank's
    /// headroom figures on every redraw. Keep the last few around.
    public static func cached(profile: BinauralProfile, sampleRate: Double) -> HRIRBank {
        cacheLock.lock()
        if let hit = cache.first(where: { $0.profile == profile && $0.rate == sampleRate }) {
            cacheLock.unlock()
            return hit.bank
        }
        cacheLock.unlock()
        let bank = generate(profile: profile, sampleRate: sampleRate)
        cacheLock.lock()
        cache.insert((profile, sampleRate, bank), at: 0)
        if cache.count > 4 { cache.removeLast() }
        cacheLock.unlock()
        return bank
    }
}
