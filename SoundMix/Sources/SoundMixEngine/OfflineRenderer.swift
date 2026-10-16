import Foundation
import AVFoundation
import Synchronization
import Darwin

/// Folds a multichannel file down to stereo without touching an audio device.
///
/// The original app can only downmix a live input, so checking a mix means
/// routing it through a loopback device in real time. This runs the identical
/// processing chain over a file as fast as the disk allows.
public final class OfflineRenderer {

    public struct Result: Sendable {
        public var outputURL: URL
        public var frames: Int
        public var sampleRate: Double
        public var inputChannels: Int
        public var duration: TimeInterval
        public var peakLeftDB: Double
        public var peakRightDB: Double
        public var maxGainReductionDB: Double
        public var clippedSamples: Int
        public var renderTime: TimeInterval

        /// How much faster than real time the render ran.
        public var speedFactor: Double {
            renderTime > 0 ? duration / renderTime : 0
        }
    }

    public enum RenderError: LocalizedError {
        case unreadable(URL, String)
        case noChannels
        case tooFewChannels(have: Int, need: Int, layout: String)
        case cannotWrite(URL, String)
        case cancelled
        case sameFile

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let why):
                return "Could not read “\(url.lastPathComponent)”: \(why)"
            case .noChannels:
                return "That file has no audio channels."
            case .tooFewChannels(let have, let need, let layout):
                return "The file has \(have) channel\(have == 1 ? "" : "s") but the \(layout) layout needs \(need). Pick a layout that matches the file."
            case .cannotWrite(let url, let why):
                return "Could not write “\(url.lastPathComponent)”: \(why)"
            case .sameFile:
                return "Choose an output file different from the source."
            case .cancelled:
                return "Render cancelled."
            }
        }
    }

    /// What an input file looks like, before committing to a render.
    public struct SourceInfo: Sendable {
        public var url: URL
        public var channels: Int
        public var sampleRate: Double
        public var frames: Int
        public var duration: TimeInterval
        public var suggestedLayout: LayoutPreset?
    }

    public init() {}

    /// Inspect a file and suggest the layout whose channel count matches.
    public static func inspect(_ url: URL) throws -> SourceInfo {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw RenderError.unreadable(url, error.localizedDescription) }

        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard channels > 0 else { throw RenderError.noChannels }
        let frames = Int(file.length)
        let rate = format.sampleRate
        // A file whose header claims no frames would otherwise "render"
        // successfully and produce silence.
        guard frames > 0 else {
            throw RenderError.unreadable(url, "the file header reports no audio frames")
        }

        // Prefer the smallest preset that the file can actually fill, so a
        // 6-channel file suggests 5.1 rather than being forced into 9.1.6.
        let suggested = LayoutPreset.all
            .filter { $0.requiredInputChannels <= channels }
            .max { $0.requiredInputChannels < $1.requiredInputChannels }

        return SourceInfo(url: url, channels: channels, sampleRate: rate, frames: frames,
                          duration: rate > 0 ? Double(frames) / rate : 0,
                          suggestedLayout: suggested)
    }

    private let cancelled = Atomic<Bool>(false)
    public func cancel() { cancelled.store(true, ordering: .releasing) }

    /// Render `input` through `configuration` and write stereo to `output`.
    /// `progress` is called on an arbitrary thread with a 0…1 fraction.
    public func render(input: URL,
                       output: URL,
                       configuration: ProcessorConfiguration,
                       bitDepth: Int = 24,
                       progress: ((Double) -> Void)? = nil) throws -> Result {
        let sourcePath = input.resolvingSymlinksInPath().standardizedFileURL
        let outputPath = output.resolvingSymlinksInPath().standardizedFileURL
        let sourceID = try? input.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let outputID = try? output.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let sameIdentity = (sourceID as? NSObject).map { $0.isEqual(outputID) } ?? false
        guard sourcePath != outputPath, !sameIdentity else { throw RenderError.sameFile }
        if cancelled.load(ordering: .acquiring) { throw RenderError.cancelled }

        // Publish only a complete file. Failed/cancelled renders leave an
        // existing destination intact, and never leave a partial final export.
        let staging = output.deletingLastPathComponent()
            .appendingPathComponent(".soundmix-\(UUID().uuidString).\(output.pathExtension.isEmpty ? "wav" : output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        var result = try renderContents(input: input, output: staging,
                                        configuration: configuration, bitDepth: bitDepth,
                                        progress: progress)
        if cancelled.load(ordering: .acquiring) { throw RenderError.cancelled }
        guard rename(staging.path, output.path) == 0 else {
            throw RenderError.cannotWrite(output, String(cString: strerror(errno)))
        }
        result.outputURL = output
        progress?(1)
        return result
    }

    private func renderContents(input: URL, output: URL,
                                configuration: ProcessorConfiguration, bitDepth: Int,
                                progress: ((Double) -> Void)?) throws -> Result {
        let started = Date()
        let info = try Self.inspect(input)
        let needed = configuration.layout.requiredInputChannels
        guard info.channels >= needed else {
            throw RenderError.tooFewChannels(have: info.channels, need: needed,
                                             layout: configuration.layout.name)
        }

        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let rate = format.sampleRate

        // The processor is prepared at the file's rate, so filters and the
        // limiter's look-ahead are correct for this material.
        let processor = SoundMixProcessor()
        processor.applyNow(configuration)
        processor.prepare(sampleRate: rate)
        processor.applyNow(configuration)
        processor.reset()

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: bitDepth == 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if bitDepth == 32 { settings[AVLinearPCMIsFloatKey] = true }

        let outFile: AVAudioFile
        do { outFile = try AVAudioFile(forWriting: output, settings: settings) }
        catch { throw RenderError.cannotWrite(output, error.localizedDescription) }

        let blockFrames = 4096
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw RenderError.unreadable(input, "could not allocate a read buffer")
        }
        // AVAudioFile writes through its own processing format, which is
        // deinterleaved float regardless of the on-disk layout requested above.
        // Handing it an interleaved buffer fails with a bare -50.
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw RenderError.cannotWrite(output, "could not allocate a write buffer")
        }

        var interleaved = [Float](repeating: 0, count: blockFrames * channels)
        var stereo = [Float](repeating: 0, count: blockFrames * 2)

        var framesDone = 0
        var peakL = 0.0, peakR = 0.0
        var maxGR = 0.0
        var clipped = 0
        let total = max(info.frames, 1)

        while true {
            if cancelled.load(ordering: .acquiring) { throw RenderError.cancelled }
            readBuffer.frameLength = 0
            let remaining = file.length - file.framePosition
            if remaining <= 0 { break }
            let want = AVAudioFrameCount(min(Int64(blockFrames), remaining))
            do { try file.read(into: readBuffer, frameCount: want) }
            catch { throw RenderError.unreadable(input, error.localizedDescription) } // EOF is checked above.
            let n = Int(readBuffer.frameLength)
            if n == 0 { throw RenderError.unreadable(input, "unexpected end of audio data") }

            // AVAudioFile hands back deinterleaved float; the processor wants
            // the interleaved layout a device would give it.
            if let src = readBuffer.floatChannelData {
                for c in 0..<channels {
                    let plane = src[c]
                    for f in 0..<n { interleaved[f * channels + c] = plane[f] }
                }
            }

            interleaved.withUnsafeBufferPointer { inPtr in
                stereo.withUnsafeMutableBufferPointer { outPtr in
                    processor.process(input: inPtr.baseAddress!, inputChannels: channels,
                                      frames: n, output: outPtr.baseAddress!)
                }
            }

            for f in 0..<n {
                let l = Double(stereo[f * 2]), r = Double(stereo[f * 2 + 1])
                peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
                if abs(l) >= 0.99999 || abs(r) >= 0.99999 { clipped += 1 }
            }
            let snap = processor.snapshot()
            maxGR = max(maxGR, snap.gainReductionDB)

            writeBuffer.frameLength = AVAudioFrameCount(n)
            if let dst = writeBuffer.floatChannelData {
                for f in 0..<n { dst[0][f] = stereo[f * 2]; dst[1][f] = stereo[f * 2 + 1] }
            }
            do { try outFile.write(from: writeBuffer) }
            catch { throw RenderError.cannotWrite(output, error.localizedDescription) }

            framesDone += n
            progress?(min(Double(framesDone) / Double(total), 0.99))
        }

        // Flush the chain's own latency so the tail is not truncated.
        let tail = Int((processor.latencyMS / 1000 * rate).rounded())
        interleaved.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        var remainingTail = tail
        while remainingTail > 0 {
            if cancelled.load(ordering: .acquiring) { throw RenderError.cancelled }
            let n = min(remainingTail, blockFrames)
            interleaved.withUnsafeBufferPointer { input in
                stereo.withUnsafeMutableBufferPointer { output in
                    processor.process(input: input.baseAddress!, inputChannels: channels,
                                      frames: n, output: output.baseAddress!)
                }
            }
            for f in 0..<n {
                let l = Double(stereo[f * 2]), r = Double(stereo[f * 2 + 1])
                peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
                if abs(l) >= 0.99999 || abs(r) >= 0.99999 { clipped += 1 }
            }
            maxGR = max(maxGR, processor.snapshot().gainReductionDB)
            writeBuffer.frameLength = AVAudioFrameCount(n)
            if let dst = writeBuffer.floatChannelData {
                for f in 0..<n { dst[0][f] = stereo[f * 2]; dst[1][f] = stereo[f * 2 + 1] }
            }
            do { try outFile.write(from: writeBuffer) }
            catch { throw RenderError.cannotWrite(output, error.localizedDescription) }
            framesDone += n
            remainingTail -= n
        }

        return Result(outputURL: output,
                      frames: framesDone,
                      sampleRate: rate,
                      inputChannels: channels,
                      duration: Double(framesDone) / rate,
                      peakLeftDB: peakL > 0 ? 20 * log10(peakL) : -.infinity,
                      peakRightDB: peakR > 0 ? 20 * log10(peakR) : -.infinity,
                      maxGainReductionDB: maxGR,
                      clippedSamples: clipped,
                      renderTime: Date().timeIntervalSince(started))
    }
}
