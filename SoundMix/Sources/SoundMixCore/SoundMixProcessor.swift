import Foundation
import os
import Synchronization

/// Everything that defines how a bed is folded to stereo.
public struct ProcessorConfiguration: Equatable, Sendable {
    public var layout: LayoutPreset
    public var recipe: MatrixRecipe
    public var headroomMode: HeadroomMode
    public var manualGainDB: Double
    public var swapOutputs: Bool
    public var globalPEQ: PEQProfile
    public var speakerPEQLeft: PEQProfile
    public var speakerPEQRight: PEQProfile
    public var limiter: TruePeakLimiter.Settings
    /// `nil` lets the processor align the dry path to the LFE filter's DC group delay.
    public var lfeDelayOverrideSamples: Int?
    /// When set, the bed is folded through a head-related filter bank instead of
    /// `recipe`'s amplitude matrix. The recipe is kept so the interface can show
    /// what the amplitude fold would have been, but it is not rendered.
    public var binaural: BinauralProfile?

    public init(layout: LayoutPreset = .nativeBed,
                recipe: MatrixRecipe = .reference,
                headroomMode: HeadroomMode = .powerPreserving,
                manualGainDB: Double = 0,
                swapOutputs: Bool = false,
                globalPEQ: PEQProfile = .flat,
                speakerPEQLeft: PEQProfile = .flat,
                speakerPEQRight: PEQProfile = .flat,
                limiter: TruePeakLimiter.Settings = .init(),
                lfeDelayOverrideSamples: Int? = nil,
                binaural: BinauralProfile? = nil) {
        self.layout = layout
        self.recipe = recipe
        self.headroomMode = headroomMode
        self.manualGainDB = manualGainDB
        self.swapOutputs = swapOutputs
        self.globalPEQ = globalPEQ
        self.speakerPEQLeft = speakerPEQLeft
        self.speakerPEQRight = speakerPEQRight
        self.limiter = limiter
        self.lfeDelayOverrideSamples = lfeDelayOverrideSamples
        self.binaural = binaural
    }

    /// The matrix this configuration produces, restricted to the channels the
    /// layout actually feeds, before any trim.
    public var effectiveMatrix: SoundMixMatrix {
        recipe.matrix().restricted(to: layout.activeChannels)
    }

    public var isBinaural: Bool { binaural != nil }

    /// The LFE handling the active fold asks for. The LFE never goes through the
    /// filter bank — direction is not carried down there — so both folds treat
    /// it the same way, with their own cutoff, slope and gain.
    public var lfeSettings: LFESettings { binaural?.lfe ?? recipe.lfeSettings }

    /// The rate the binaural headroom figures are computed at. The bank itself
    /// is built for the device rate, but the trim comes from the 48 kHz bank so
    /// that the level does not shift when the device changes rate. The figures
    /// move by hundredths of a dB between rates; the limiter remains the final
    /// guarantee either way.
    public static let binauralReferenceSampleRate = 48_000.0

    /// The filter bank this configuration folds through, or `nil` in matrix mode.
    public func bank(sampleRate: Double) -> HRIRBank? {
        guard let profile = binaural else { return nil }
        return HRIRBank.cached(profile: profile, sampleRate: sampleRate)
    }

    /// Worst-case (L1) and uncorrelated (L2) gain of whichever fold is active.
    ///
    /// For the matrix these are the norms of its coefficients. For the filter
    /// bank they are the same norms taken over whole impulse responses — the
    /// sum of absolute taps bounds the peak, the root of the summed tap energy
    /// gives the level for uncorrelated material — with the LFE row counted
    /// exactly as the matrix path counts it.
    public var foldGains: (peak: Double, power: Double) {
        guard let profile = binaural else {
            let m = effectiveMatrix
            return (m.worstCasePeakGain, m.uncorrelatedGain)
        }
        let bank = HRIRBank.cached(profile: profile,
                                   sampleRate: Self.binauralReferenceSampleRate)
        let channels = layout.activeChannels
        var peak = bank.worstCasePeakGain(for: channels)
        var power = bank.uncorrelatedGain(for: channels)
        if channels.contains(.lfe), profile.lfe.mode != .off {
            let g = abs(SoundMixMatrix.linear(profile.lfe.gainDB))
            peak += g
            power = (power * power + g * g).squareRoot()
        }
        return (peak, power)
    }

    public var foldPeakGainDB: Double { SoundMixMatrix.dB(foldGains.peak) }
    public var foldPowerGainDB: Double { SoundMixMatrix.dB(foldGains.power) }

    /// The automatic trim in dB that `headroomMode` asks for.
    public var automaticTrimDB: Double {
        let gains = foldGains
        switch headroomMode {
        case .none:            return 0
        case .peakSafe:        return gains.peak > 1 ? -SoundMixMatrix.dB(gains.peak) : 0
        case .powerPreserving: return gains.power > 1 ? -SoundMixMatrix.dB(gains.power) : 0
        }
    }

    public var totalTrimDB: Double { automaticTrimDB + manualGainDB }
}

/// The real-time downmix engine. One instance owns all filter state.
///
/// Signal flow, matching the original renderer's ordering so existing PEQ
/// profiles behave the same, with the limiter added at the end:
///
/// ```
/// device in → input map → bed[16]
///                          ├── LFE → (Butterworth LP | dry | off) → ×coef ─┐
///                          └── everything else → matrix → dry L/R → delay ─┤
///                                                                           ▼
///              global PEQ (both channels) → swap → speaker PEQ L/R → limiter → out
/// ```
///
/// In binaural mode the matrix is replaced by a head-related filter bank, and
/// the bass is split out of it so direction is only imposed where the ear can
/// use it:
///
/// ```
/// bed[16] ─┬── HRIR bank (15 convolutions) → L/R → LR4 high-pass ─┐
///          ├── Σ bass weights → delay → LR4 low-pass ─────────────┤ (both ears)
///          └── LFE → (low-pass | dry | off) → ×gain ──────────────┘
/// ```
private final class ProcessorRenderState: @unchecked Sendable {

    // Audio-thread state -----------------------------------------------------
    private var sampleRate: Double = 48_000
    private var coefficients: [Double] = Array(repeating: 0, count: BedChannel.count * 2)
    private var inputMap: [Int] = Array(repeating: -1, count: BedChannel.count)   // 0-based, -1 = unmapped
    private var swap = false

    private let lfeFilter = BiquadChain()
    private var lfeEnabled = false
    private let globalLeft = BiquadChain(), globalRight = BiquadChain()
    private let speakerLeft = BiquadChain(), speakerRight = BiquadChain()
    private let limiter = TruePeakLimiter()

    private var dryDelay: [Double] = []            // interleaved L,R
    private var dryDelayFrames = 0
    private var dryDelayIndex = 0

    // Binaural fold. Everything here is unused in matrix mode.
    static let blockCapacity = 512
    private var binauralEngine: BinauralFoldEngine?
    private var bank: HRIRBank?
    private var bedBlocks: [Double] = []
    private var foldL: [Double] = [], foldR: [Double] = []
    private var lfeBlock: [Double] = [], bassBlock: [Double] = []
    private var bassWeights = [Double](repeating: 0, count: BedChannel.count)
    private let bassLowPass = BiquadChain()
    private let bassHighLeft = BiquadChain(), bassHighRight = BiquadChain()
    private var crossoverEnabled = false
    private var bassDelay: [Double] = []
    private var bassDelayFrames = 0
    private var bassDelayIndex = 0

    private var bed = [Double](repeating: 0, count: BedChannel.count)
    private var snapshotPeaks = [Double](repeating: -.infinity, count: BedChannel.count)
    private var bedMeters = [LevelMeter](repeating: LevelMeter(), count: BedChannel.count)
    private var meterLeft = LevelMeter(), meterRight = LevelMeter()
    private var appliedTrimDB: Double = 0
    /// Read by the UI thread without a lock, so it accumulates atomically.
    private let underruns = Atomic<Int>(0)

    // Shared state -----------------------------------------------------------
    // os_unfair_lock must live at a fixed address. Taking `&someStoredProperty`
    // does not guarantee one — the optimiser is free to hand the call a
    // temporary copy, which silently removes the mutual exclusion. Allocating
    // the locks once pins them for the object's lifetime.
    private let snapshotLock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var snapshotStorage = RenderSnapshot(bedPeakDB: [])
    public private(set) var configuration = ProcessorConfiguration()

    public init() {}

    deinit {
        snapshotLock.deinitialize(count: 1); snapshotLock.deallocate()
    }

    // MARK: - Setup

    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in bedMeters.indices { bedMeters[i].configure(sampleRate: sampleRate) }
        meterLeft.configure(sampleRate: sampleRate)
        meterRight.configure(sampleRate: sampleRate)
        limiter.update(settings: configuration.limiter, sampleRate: sampleRate)
        rebuild(configuration)
    }

    /// Apply immediately on the current thread. Only for offline use and setup.
    public func applyNow(_ config: ProcessorConfiguration) {
        rebuild(config)
    }

    private func rebuild(_ config: ProcessorConfiguration) {
        configuration = config

        let trimDB = config.totalTrimDB
        appliedTrimDB = trimDB
        let trim = SoundMixMatrix.linear(trimDB)
        let lfeConfig = config.lfeSettings

        if let profile = config.binaural {
            // The trim is baked into the taps and the bass weights, so the fold
            // output is already at its final level before the EQ sees it.
            let generated = HRIRBank.cached(profile: profile, sampleRate: sampleRate)
                .scaled(by: trim)
            bank = generated
            binauralEngine = BinauralFoldEngine(bank: generated,
                                                blockCapacity: Self.blockCapacity)
            allocateBlockBuffers()
            for c in 0..<BedChannel.count { bassWeights[c] = generated.bassWeights[c] }

            // Only the LFE row of the matrix is used in binaural mode.
            for i in coefficients.indices { coefficients[i] = 0 }
            let g = lfeConfig.mode == .off ? 0 : SoundMixMatrix.linear(lfeConfig.gainDB) * trim
            coefficients[BedChannel.lfe.rawValue * 2] = g
            coefficients[BedChannel.lfe.rawValue * 2 + 1] = g

            if profile.bassCrossoverHz > 20, profile.bassCrossoverHz < sampleRate * 0.45 {
                let xo = BiquadDesign.linkwitzRiley4(frequency: profile.bassCrossoverHz,
                                                     sampleRate: sampleRate)
                bassLowPass.update(xo.low)
                bassHighLeft.update(xo.high)
                bassHighRight.update(xo.high)
                crossoverEnabled = true
                bassDelayFrames = generated.referenceDelaySamples
            } else {
                bassLowPass.update(BiquadCascade())
                bassHighLeft.update(BiquadCascade())
                bassHighRight.update(BiquadCascade())
                crossoverEnabled = false
                bassDelayFrames = 0
            }
            if bassDelay.count != bassDelayFrames {
                bassDelay = Array(repeating: 0, count: bassDelayFrames)
                bassDelayIndex = 0
            }
        } else {
            bank = nil
            binauralEngine = nil
            crossoverEnabled = false
            bassDelayFrames = 0
            let matrix = config.effectiveMatrix.scaled(by: trim)
            for ch in BedChannel.allCases {
                coefficients[ch.rawValue * 2] = matrix[ch].left
                coefficients[ch.rawValue * 2 + 1] = matrix[ch].right
            }
        }

        for ch in BedChannel.allCases {
            let slot = config.layout.map[ch.rawValue]
            inputMap[ch.rawValue] = slot > 0 ? slot - 1 : -1
        }

        swap = config.swapOutputs

        // LFE path.
        switch lfeConfig.mode {
        case .off:
            lfeEnabled = false
            lfeFilter.update(BiquadCascade())
        case .dry:
            lfeEnabled = true
            lfeFilter.update(BiquadCascade())
        case .lowPass:
            lfeEnabled = true
            lfeFilter.update(BiquadDesign.butterworthLowPass(
                frequency: lfeConfig.cutoffHz,
                order: lfeConfig.filterOrder,
                sampleRate: sampleRate))
        }

        // Align the dry path with the LFE filter so the bass sums in phase.
        let autoDelay: Int
        if lfeConfig.mode == .lowPass, lfeEnabled {
            let tau = lfeFilter.cascade.groupDelay(at: 0, sampleRate: sampleRate)
            autoDelay = max(0, Int(tau.rounded()))
        } else {
            autoDelay = 0
        }
        let frames = max(1, config.lfeDelayOverrideSamples ?? autoDelay)
        if frames != dryDelayFrames {
            dryDelayFrames = frames
            dryDelay = Array(repeating: 0, count: frames * 2)
            dryDelayIndex = 0
        }

        globalLeft.update(config.globalPEQ.cascade(sampleRate: sampleRate))
        globalRight.update(config.globalPEQ.cascade(sampleRate: sampleRate))
        speakerLeft.update(config.speakerPEQLeft.cascade(sampleRate: sampleRate))
        speakerRight.update(config.speakerPEQRight.cascade(sampleRate: sampleRate))
        limiter.update(settings: config.limiter, sampleRate: sampleRate)
    }

    /// Allocated once per render state, on the control thread, so the audio
    /// thread never sizes a buffer.
    private func allocateBlockBuffers() {
        let cap = Self.blockCapacity
        if bedBlocks.count != BedChannel.count * cap {
            bedBlocks = Array(repeating: 0, count: BedChannel.count * cap)
        }
        if foldL.count != cap {
            foldL = Array(repeating: 0, count: cap)
            foldR = Array(repeating: 0, count: cap)
            lfeBlock = Array(repeating: 0, count: cap)
            bassBlock = Array(repeating: 0, count: cap)
        }
    }

    func inheritHistory(from previous: ProcessorRenderState) {
        lfeFilter.inheritHistory(from: previous.lfeFilter)
        globalLeft.inheritHistory(from: previous.globalLeft)
        globalRight.inheritHistory(from: previous.globalRight)
        speakerLeft.inheritHistory(from: previous.speakerLeft)
        speakerRight.inheritHistory(from: previous.speakerRight)
        limiter.inheritHistory(from: previous.limiter)
        bassLowPass.inheritHistory(from: previous.bassLowPass)
        bassHighLeft.inheritHistory(from: previous.bassHighLeft)
        bassHighRight.inheritHistory(from: previous.bassHighRight)
        if let engine = binauralEngine, let old = previous.binauralEngine {
            engine.inheritHistory(from: old)
        }
        if bassDelay.count == previous.bassDelay.count {
            for i in bassDelay.indices { bassDelay[i] = previous.bassDelay[i] }
            bassDelayIndex = previous.bassDelayIndex
        }
        if dryDelay.count == previous.dryDelay.count {
            for i in dryDelay.indices { dryDelay[i] = previous.dryDelay[i] }
            dryDelayIndex = previous.dryDelayIndex
        }
        for i in bedMeters.indices { bedMeters[i] = previous.bedMeters[i] }
        meterLeft = previous.meterLeft; meterRight = previous.meterRight
        underruns.store(previous.underruns.load(ordering: .relaxed), ordering: .relaxed)
    }

    public func reset() {
        lfeFilter.reset(); globalLeft.reset(); globalRight.reset()
        speakerLeft.reset(); speakerRight.reset(); limiter.reset()
        bassLowPass.reset(); bassHighLeft.reset(); bassHighRight.reset()
        binauralEngine?.reset()
        for i in bassDelay.indices { bassDelay[i] = 0 }
        bassDelayIndex = 0
        for i in dryDelay.indices { dryDelay[i] = 0 }
        dryDelayIndex = 0
        for i in bedMeters.indices { bedMeters[i].reset() }
        meterLeft.reset(); meterRight.reset()
        underruns.store(0, ordering: .relaxed)
    }

    public func noteUnderrun() { underruns.wrappingAdd(1, ordering: .relaxed) }

    /// Total added latency of the processing chain, in milliseconds.
    public var latencyMS: Double {
        (Double(dryDelayFrames == 1 ? 0 : dryDelayFrames)
            + Double(limiter.latencySamples)
            + Double(bank?.referenceDelaySamples ?? 0))
            / sampleRate * 1000
    }

    // MARK: - Render

    /// Fold `frames` of interleaved input into interleaved stereo output.
    public func process(input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                        output: UnsafeMutablePointer<Float>) {
        if let engine = binauralEngine {
            processBinaural(engine: engine, input: input, inputChannels: inputChannels,
                            frames: frames, output: output)
        } else {
            processMatrix(input: input, inputChannels: inputChannels,
                          frames: frames, output: output)
        }
        publishSnapshot()
    }

    /// Everything after the fold: the LFE sum, the dry delay, both EQ stages,
    /// the output swap and the limiter. Shared by both folds so the output
    /// stage can only ever behave one way.
    @inline(__always)
    private func finishFrame(_ dryL: Double, _ dryR: Double, lfeRaw: Double) -> (Double, Double) {
        // Delay the dry path by the LFE filter's group delay.
        var outL: Double, outR: Double
        if dryDelayFrames > 1 {
            let idx = dryDelayIndex * 2
            outL = dryDelay[idx]
            outR = dryDelay[idx + 1]
            dryDelay[idx] = dryL
            dryDelay[idx + 1] = dryR
            dryDelayIndex = (dryDelayIndex + 1) % dryDelayFrames
        } else {
            outL = dryL
            outR = dryR
        }

        if lfeEnabled {
            let lfe = lfeFilter.cascade.sections.isEmpty ? lfeRaw : lfeFilter.process(lfeRaw)
            outL += lfe * coefficients[BedChannel.lfe.rawValue * 2]
            outR += lfe * coefficients[BedChannel.lfe.rawValue * 2 + 1]
        }

        // Global PEQ, applied to both channels before the swap.
        if !globalLeft.cascade.isTransparent {
            outL = globalLeft.process(outL)
            outR = globalRight.process(outR)
        }

        if swap { Swift.swap(&outL, &outR) }

        // Speaker correction, applied to the physical outputs after the swap.
        if !speakerLeft.cascade.isTransparent { outL = speakerLeft.process(outL) }
        if !speakerRight.cascade.isTransparent { outR = speakerRight.process(outR) }

        limiter.process(&outL, &outR)

        meterLeft.accumulate(outL)
        meterRight.accumulate(outR)
        return (outL, outR)
    }

    private func processMatrix(input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                               output: UnsafeMutablePointer<Float>) {
        for f in 0..<frames {
            let base = f * inputChannels

            for c in 0..<BedChannel.count {
                let slot = inputMap[c]
                // Non-finite input (a wedged capture device) is muted, not
                // propagated: NaN would otherwise ride every stage downstream.
                let raw = slot >= 0 && slot < inputChannels ? Double(input[base + slot]) : 0
                let v = raw.isFinite ? raw : 0
                bed[c] = v
                bedMeters[c].accumulate(v)
            }

            // Dry sum: everything except LFE.
            var dryL = 0.0, dryR = 0.0
            for c in 0..<BedChannel.count where c != BedChannel.lfe.rawValue {
                let v = bed[c]
                if v == 0 { continue }
                dryL += v * coefficients[c * 2]
                dryR += v * coefficients[c * 2 + 1]
            }

            let (outL, outR) = finishFrame(dryL, dryR, lfeRaw: bed[BedChannel.lfe.rawValue])
            output[f * 2] = Float(outL)
            output[f * 2 + 1] = Float(outR)
        }
    }

    /// The binaural fold has to see a block at a time, so the bed is written
    /// into per-channel buffers first, convolved, and only then taken back
    /// through the per-sample output stage. Long buffers are split into chunks
    /// of `blockCapacity` so nothing is ever sized on the audio thread.
    private func processBinaural(engine: BinauralFoldEngine,
                                 input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                                 output: UnsafeMutablePointer<Float>) {
        let cap = Self.blockCapacity
        var done = 0
        while done < frames {
            let n = min(frames - done, cap)

            for f in 0..<n {
                let base = (done + f) * inputChannels
                var bass = 0.0
                for c in 0..<BedChannel.count {
                    let slot = inputMap[c]
                    // Non-finite input is muted here, at the single point both
                    // folds read the device, so no downstream stage sees it.
                    let raw = slot >= 0 && slot < inputChannels ? Double(input[base + slot]) : 0
                    let v = raw.isFinite ? raw : 0
                    bed[c] = v
                    bedMeters[c].accumulate(v)
                    bedBlocks[c * cap + f] = v
                    if c != BedChannel.lfe.rawValue { bass += v * bassWeights[c] }
                }
                lfeBlock[f] = bed[BedChannel.lfe.rawValue]
                bassBlock[f] = bass
            }

            bedBlocks.withUnsafeBufferPointer { bedBuffer in
                foldL.withUnsafeMutableBufferPointer { left in
                    foldR.withUnsafeMutableBufferPointer { right in
                        engine.process(bed: bedBuffer.baseAddress!, bedStride: cap, frames: n,
                                       outL: left.baseAddress!, outR: right.baseAddress!)
                    }
                }
            }

            for f in 0..<n {
                var l = foldL[f], r = foldR[f]

                // Below the crossover the fold collapses to the centre: the ear
                // takes no direction from there, and per-ear filtering of the
                // bass only combs. The two legs are Linkwitz-Riley, so they sum
                // back to a flat magnitude.
                if crossoverEnabled {
                    l = bassHighLeft.process(l)
                    r = bassHighRight.process(r)
                    var low = bassBlock[f]
                    if bassDelayFrames > 0 {
                        let idx = bassDelayIndex
                        let held = bassDelay[idx]
                        bassDelay[idx] = low
                        bassDelayIndex = (idx + 1) % bassDelayFrames
                        low = held
                    }
                    low = bassLowPass.process(low)
                    l += low
                    r += low
                }

                let (outL, outR) = finishFrame(l, r, lfeRaw: lfeBlock[f])
                output[(done + f) * 2] = Float(outL)
                output[(done + f) * 2 + 1] = Float(outR)
            }

            done += n
        }
    }

    private func publishSnapshot() {
        guard os_unfair_lock_trylock(snapshotLock) else { return }
        defer { os_unfair_lock_unlock(snapshotLock) }
        for i in snapshotPeaks.indices { snapshotPeaks[i] = bedMeters[i].peakDB }
        let snap = RenderSnapshot(
            bedPeakDB: [],
            outputPeakDB: (meterLeft.peakDB, meterRight.peakDB),
            outputRMSDB: (meterLeft.rmsDB, meterRight.rmsDB),
            clipLeft: meterLeft.clipCount,
            clipRight: meterRight.clipCount,
            gainReductionDB: limiter.takeGainReductionDB(),
            appliedTrimDB: appliedTrimDB,
            latencyMS: latencyMS,
            sampleRate: sampleRate,
            isRunning: true,
            underruns: underruns.load(ordering: .acquiring))
        snapshotStorage = snap
    }

    public func snapshot() -> RenderSnapshot {
        os_unfair_lock_lock(snapshotLock)
        var s = snapshotStorage
        // Allocate the public array only on the snapshot reader's thread.
        s.bedPeakDB = snapshotPeaks.map { $0 }
        os_unfair_lock_unlock(snapshotLock)
        return s
    }

    public func markStopped() {
        os_unfair_lock_lock(snapshotLock)
        snapshotStorage.isRunning = false
        os_unfair_lock_unlock(snapshotLock)
    }
}

/// Control-thread preparation with a nonblocking handoff to the audio thread.
/// Replaced states are retained until the next control-thread update, so their
/// arrays and filters are never destroyed by the real-time callback.
public final class SoundMixProcessor: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var current = ProcessorRenderState()
    private var pending: ProcessorRenderState?
    private var retired: ProcessorRenderState?
    private var sampleRate: Double = 48_000
    public init() {}
    deinit { lock.deinitialize(count: 1); lock.deallocate() }

    private func readState() -> ProcessorRenderState {
        os_unfair_lock_lock(lock)
        let state = current
        os_unfair_lock_unlock(lock)
        return state
    }
    public var configuration: ProcessorConfiguration { readState().configuration }
    public var latencyMS: Double { readState().latencyMS }

    /// A private build of a fresh render state holding `config`, prepared for
    /// `sampleRate`. Everything that mutates render state happens here, on the
    /// calling (control) thread, so the audio thread only ever swaps whole
    /// states under the lock — it never mutates a state it might be reading.
    private func makeState(config: ProcessorConfiguration, sampleRate: Double,
                           inheritingFrom previous: ProcessorRenderState?) -> ProcessorRenderState {
        let next = ProcessorRenderState()
        next.applyNow(config)
        next.prepare(sampleRate: sampleRate)
        if let previous { next.inheritHistory(from: previous) }
        return next
    }

    /// Replace the state now, synchronously, carrying filter history across so
    /// the rebuild is equivalent to the in-place rebuild this used to be. For
    /// offline rendering and bring-up (before the audio units exist).
    public func applyNow(_ config: ProcessorConfiguration) {
        let previous = readState()
        let next = makeState(config: config, sampleRate: sampleRate, inheritingFrom: previous)
        os_unfair_lock_lock(lock)
        retired = current
        current = next
        pending = nil
        os_unfair_lock_unlock(lock)
    }

    /// Re-prepare for a new sample rate. Rebuilds the current configuration
    /// (coefficients are rate-dependent) on a fresh state, keeping history,
    /// swapped under the lock.
    public func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        let previous = readState()
        let next = makeState(config: previous.configuration, sampleRate: sampleRate,
                             inheritingFrom: previous)
        os_unfair_lock_lock(lock)
        retired = current
        current = next
        pending = nil
        os_unfair_lock_unlock(lock)
    }

    /// Reset all filter and meter history. Rebuilds a clean state that keeps
    /// the current configuration, swapped under the lock.
    public func reset() {
        let previous = readState()
        let next = makeState(config: previous.configuration, sampleRate: sampleRate,
                             inheritingFrom: nil)
        os_unfair_lock_lock(lock)
        retired = current
        current = next
        pending = nil
        os_unfair_lock_unlock(lock)
    }
    public func markStopped() { readState().markStopped() }
    public func snapshot() -> RenderSnapshot { readState().snapshot() }

    /// Queue a configuration change. Safe to call from any thread; the audio
    /// thread picks it up at the start of its next block, inheriting history
    /// from the state it replaces so live edits do not click.
    public func apply(_ config: ProcessorConfiguration) {
        let next = makeState(config: config, sampleRate: sampleRate, inheritingFrom: nil)
        os_unfair_lock_lock(lock)
        retired = nil
        pending = next
        os_unfair_lock_unlock(lock)
    }

    public func noteUnderrun() { current.noteUnderrun() }
    public func process(input: UnsafePointer<Float>, inputChannels: Int, frames: Int,
                        output: UnsafeMutablePointer<Float>) {
        if os_unfair_lock_trylock(lock) {
            if let next = pending, retired == nil {
                next.inheritHistory(from: current)
                retired = current
                current = next
                pending = nil
            }
            os_unfair_lock_unlock(lock)
        }
        current.process(input: input, inputChannels: inputChannels, frames: frames, output: output)
    }
}
