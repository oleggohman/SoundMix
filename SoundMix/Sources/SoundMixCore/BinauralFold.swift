import Foundation
import Accelerate

/// The render-side binaural fold: a bank of FIRs convolved against the bed and
/// summed into two ears.
///
/// A mirror-symmetric bank needs half the convolutions it looks like it needs.
/// For a mirrored pair the left-side channel reaches the near ear through `I`
/// and the far ear through `C`, and the right-side channel reaches them the
/// other way round, so with `s = xL + xR` and `d = xL − xR`:
///
/// ```
/// left  = ((I+C)/2)·s + ((I−C)/2)·d
/// right = ((I+C)/2)·s − ((I−C)/2)·d
/// ```
///
/// which is two convolutions per pair instead of four. Seven mirrored pairs
/// plus the centre channel come to fifteen convolutions per block rather than
/// twenty-nine.
///
/// All storage is allocated when the engine is built, on the control thread.
/// `process` allocates nothing, locks nothing and does no work proportional to
/// anything but the block length.
final class BinauralFoldEngine {

    /// One fold unit: a mirrored pair, or a single centre channel.
    private struct Unit {
        let a: Int
        let b: Int
        let paired: Bool
    }

    private static let pairs: [(BedChannel, BedChannel?)] = [
        (.l, .r), (.lw, .rw), (.ls, .rs), (.lrs, .rrs),
        (.ltf, .rtf), (.ltm, .rtm), (.ltr, .rtr), (.c, nil),
    ]

    let tapCount: Int
    let blockCapacity: Int
    private let units: [Unit]
    private let regionStride: Int

    private let sumTaps: UnsafeMutablePointer<Double>    // reversed, per unit
    private let diffTaps: UnsafeMutablePointer<Double>
    private let sumWork: UnsafeMutablePointer<Double>    // history + block, per unit
    private let diffWork: UnsafeMutablePointer<Double>
    private let scratchSum: UnsafeMutablePointer<Double>
    private let scratchDiff: UnsafeMutablePointer<Double>

    init(bank: HRIRBank, blockCapacity: Int) {
        self.tapCount = bank.tapCount
        self.blockCapacity = blockCapacity
        self.regionStride = bank.tapCount - 1 + blockCapacity
        self.units = Self.pairs.map {
            Unit(a: $0.0.rawValue, b: ($0.1 ?? $0.0).rawValue, paired: $0.1 != nil)
        }

        let count = units.count * tapCount
        sumTaps = .allocate(capacity: count)
        diffTaps = .allocate(capacity: count)
        sumTaps.initialize(repeating: 0, count: count)
        diffTaps.initialize(repeating: 0, count: count)

        let work = units.count * regionStride
        sumWork = .allocate(capacity: work)
        diffWork = .allocate(capacity: work)
        sumWork.initialize(repeating: 0, count: work)
        diffWork.initialize(repeating: 0, count: work)

        scratchSum = .allocate(capacity: blockCapacity)
        scratchDiff = .allocate(capacity: blockCapacity)
        scratchSum.initialize(repeating: 0, count: blockCapacity)
        scratchDiff.initialize(repeating: 0, count: blockCapacity)

        // vDSP_conv slides the filter forwards, so the taps go in reversed.
        for (u, unit) in units.enumerated() {
            let a = BedChannel(rawValue: unit.a)!
            let ipsi = Array(bank.taps(a, ear: HRIRBank.leftEar))
            let contra = Array(bank.taps(a, ear: HRIRBank.rightEar))
            for n in 0..<tapCount {
                let i = ipsi[n], c = contra[n]
                let reversed = u * tapCount + (tapCount - 1 - n)
                sumTaps[reversed] = unit.paired ? (i + c) / 2 : i
                diffTaps[reversed] = unit.paired ? (i - c) / 2 : 0
            }
        }
    }

    deinit {
        sumTaps.deallocate(); diffTaps.deallocate()
        sumWork.deallocate(); diffWork.deallocate()
        scratchSum.deallocate(); scratchDiff.deallocate()
    }

    func reset() {
        let work = units.count * regionStride
        sumWork.update(repeating: 0, count: work)
        diffWork.update(repeating: 0, count: work)
    }

    /// Carry the filter history across a configuration change, when the new
    /// bank is the same shape as the old one.
    func inheritHistory(from other: BinauralFoldEngine) {
        guard other.tapCount == tapCount, other.regionStride == regionStride,
              other.units.count == units.count else { return }
        let work = units.count * regionStride
        sumWork.update(from: other.sumWork, count: work)
        diffWork.update(from: other.diffWork, count: work)
    }

    /// Fold one block. `bed[c * bedStride + f]` is bed channel `c` at frame `f`;
    /// `frames` must not exceed `blockCapacity`.
    func process(bed: UnsafePointer<Double>, bedStride: Int, frames: Int,
                 outL: UnsafeMutablePointer<Double>, outR: UnsafeMutablePointer<Double>) {
        guard frames > 0, frames <= blockCapacity else { return }
        vDSP_vclrD(outL, 1, vDSP_Length(frames))
        vDSP_vclrD(outR, 1, vDSP_Length(frames))
        let history = tapCount - 1

        for (u, unit) in units.enumerated() {
            let region = u * regionStride
            let sumRegion = sumWork + region
            let diffRegion = diffWork + region
            let a = bed + unit.a * bedStride

            if unit.paired {
                let b = bed + unit.b * bedStride
                for f in 0..<frames {
                    let xa = a[f], xb = b[f]
                    sumRegion[history + f] = xa + xb
                    diffRegion[history + f] = xa - xb
                }
            } else {
                for f in 0..<frames { sumRegion[history + f] = a[f] }
            }

            vDSP_convD(sumRegion, 1, sumTaps + u * tapCount, 1,
                       scratchSum, 1, vDSP_Length(frames), vDSP_Length(tapCount))
            if unit.paired {
                vDSP_convD(diffRegion, 1, diffTaps + u * tapCount, 1,
                           scratchDiff, 1, vDSP_Length(frames), vDSP_Length(tapCount))
                for f in 0..<frames {
                    let p = scratchSum[f], m = scratchDiff[f]
                    outL[f] += p + m
                    outR[f] += p - m
                }
            } else {
                for f in 0..<frames {
                    let p = scratchSum[f]
                    outL[f] += p
                    outR[f] += p
                }
            }

            // The tail of this block becomes the next block's history. The
            // regions overlap when a block is shorter than the filter, so this
            // has to be a move, not a copy.
            if history > 0 {
                let bytes = history * MemoryLayout<Double>.stride
                memmove(sumRegion, sumRegion + frames, bytes)
                if unit.paired { memmove(diffRegion, diffRegion + frames, bytes) }
            }
        }
    }
}
