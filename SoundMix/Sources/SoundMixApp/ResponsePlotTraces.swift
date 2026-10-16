import SwiftUI

@MainActor
enum ResponsePlotTraces {
    static func make(model: AppModel, rate: Double,
                     global: PEQProfile, speakers: (left: PEQProfile, right: PEQProfile),
                     target: FrequencyResponse?) -> [ResponseCurve.Trace] {
        /// One output's full EQ: the global PEQ plus that speaker's correction.
        func eqAsProfile(_ side: EQProfile.Side) -> PEQProfile {
            var p = global
            let speaker = side == .left ? speakers.left : speakers.right
            p.filters += speaker.filters
            p.preampDB += speaker.preampDB
            return p
        }
        /// The EQ as the averaged ear hears it: the dB mean of both per-ear
        /// cascades. dB averaging commutes with the correction, so this is
        /// exactly the EQ applied to the averaged measurement.
        func averageEQPoints() -> [FrequencyResponse.Point] {
            let left = eqAsProfile(.left).cascade(sampleRate: rate)
            let right = eqAsProfile(.right).cascade(sampleRate: rate)
            return ResponseCurve.grid.map {
                .init(hz: $0, db: (left.magnitudeDB(at: $0, sampleRate: rate)
                                   + right.magnitudeDB(at: $0, sampleRate: rate)) / 2
                )
            }
        }

        guard model.averageMeasurement != nil else {
            // Nothing measured: just show what the filters themselves do.
            var out: [ResponseCurve.Trace] = [
                .fromProfile("Global", CZ.Color.blue, global, sampleRate: rate),
                .init(label: "Speaker", color: CZ.Color.purple,
                      points: averageEQPoints(), dashed: true),
            ]
            if let t = target {
                out.insert(.init(label: "Target · \(t.name)", color: CZ.Color.red,
                                 points: t.normalized().sampled(), dashed: true), at: 0)
            }
            return out
        }

        var out: [ResponseCurve.Trace] = []

        if let reference = target?.normalized() {
            out.append(.init(label: "Target · \(reference.name)", color: CZ.Color.red,
                             points: reference.sampled(), dashed: true))
        }

        // The result you will hear: each measured ear corrected by its own EQ,
        // then averaged.
        var corrected: [FrequencyResponse] = []
        for side in EQProfile.Side.allCases {
            guard let m = model.measurement(side) else { continue }
            corrected.append(FrequencyResponse(name: "",
                points: m.corrected(by: eqAsProfile(side).cascade(sampleRate: rate),
                                    sampleRate: rate)))
        }
        if let result = FrequencyResponse.average(corrected, name: "Result") {
            out.append(.init(label: "Result", color: CZ.Color.purple,
                             points: result.normalized().sampled(), emphasised: true))
        }
        return out
    }
}
