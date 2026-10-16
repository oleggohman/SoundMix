import Foundation

/// Machine-readable snapshot of what the engine is doing, refreshed while
/// rendering. The original app's only readout was a human log; this one can be
/// diffed, graphed, or checked by a test script.
///
/// Written to `~/Library/Application Support/SoundMix/telemetry.json`.
struct Telemetry: Codable {
    struct Channel: Codable {
        var slot: String
        var deviceChannel: Int
        var peakDB: Double
        var coefficientLeftDB: Double
        var coefficientRightDB: Double
    }

    var timestamp: String
    var running: Bool
    var inputDevice: String
    var outputDevice: String
    var sampleRate: Double
    var framesPerBuffer: Int
    var layout: String
    var recipe: String
    var headroomMode: String
    var swapOutputs: Bool
    var limiterEnabled: Bool
    var limiterCeilingDB: Double

    var predictedWorstCaseDB: Double
    var predictedUncorrelatedDB: Double
    var automaticTrimDB: Double
    var totalTrimDB: Double

    var chainLatencyMS: Double
    var ringUnderruns: Int
    var captureCallbacks: Int
    var captureFramesDelivered: Int
    var captureRenderErrors: Int
    var lastCaptureError: Int
    var engineStarts: Int
    var gainReductionDB: Double
    var outputPeakLeftDB: Double
    var outputPeakRightDB: Double
    var outputRMSLeftDB: Double
    var outputRMSRightDB: Double
    var clipLeft: Int
    var clipRight: Int

    var channels: [Channel]

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("telemetry.json")
    }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @MainActor
    static func capture(_ model: AppModel) -> Telemetry {
        let config = model.configuration
        let matrix = config.effectiveMatrix
        let snap = model.snapshot
        let channels = BedChannel.allCases.map { ch in
            Channel(slot: ch.shortName,
                    deviceChannel: config.layout.map[ch.rawValue],
                    peakDB: clean(snap.bedPeakDB[ch.rawValue]),
                    coefficientLeftDB: clean(SoundMixMatrix.dB(abs(matrix[ch].left))),
                    coefficientRightDB: clean(SoundMixMatrix.dB(abs(matrix[ch].right))))
        }
        return Telemetry(
            timestamp: stamp.string(from: Date()),
            running: model.state.isRunning,
            inputDevice: model.inputDevice?.name ?? "",
            outputDevice: model.outputDevice?.name ?? "",
            sampleRate: snap.sampleRate,
            framesPerBuffer: model.framesPerBuffer,
            layout: config.layout.name,
            recipe: config.recipe.name,
            headroomMode: config.headroomMode.rawValue,
            swapOutputs: config.swapOutputs,
            limiterEnabled: config.limiter.enabled,
            limiterCeilingDB: config.limiter.ceilingDB,
            predictedWorstCaseDB: clean(matrix.worstCasePeakGainDB),
            predictedUncorrelatedDB: clean(matrix.uncorrelatedGainDB),
            automaticTrimDB: clean(config.automaticTrimDB),
            totalTrimDB: clean(config.totalTrimDB),
            chainLatencyMS: snap.latencyMS,
            ringUnderruns: snap.underruns,
            captureCallbacks: model.engine.captureCallbackCount,
            captureFramesDelivered: model.engine.captureFramesDeliveredCount,
            captureRenderErrors: model.engine.captureRenderErrorCount,
            lastCaptureError: Int(model.engine.lastCaptureErrorCode),
            engineStarts: model.engine.startCount,
            gainReductionDB: snap.gainReductionDB,
            outputPeakLeftDB: clean(snap.outputPeakDB.0),
            outputPeakRightDB: clean(snap.outputPeakDB.1),
            outputRMSLeftDB: clean(snap.outputRMSDB.0),
            outputRMSRightDB: clean(snap.outputRMSDB.1),
            clipLeft: snap.clipLeft,
            clipRight: snap.clipRight,
            channels: channels)
    }

    /// JSON cannot carry infinities; the meter floor stands in for silence.
    private static func clean(_ v: Double) -> Double { v.isFinite ? v : -200 }

    /// Encode and write off the main thread: this runs twice a second while
    /// rendering and involves real disk I/O.
    private static let writerQueue = DispatchQueue(label: "io.soundmix.telemetry", qos: .utility)

    func write() {
        let value = self
        Self.writerQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: Self.url)
        }
    }
}
