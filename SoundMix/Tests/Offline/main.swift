import Foundation
import AVFoundation

var failures = 0, checks = 0
func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("  ok   \(label)") } else { failures += 1; print("  FAIL \(label) \(detail())") }
}
func near(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
    checks += 1
    if abs(a - b) <= tol { print("  ok   \(label)  (\(fmt(a)))") }
    else { failures += 1; print("  FAIL \(label): got \(fmt(a)) expected \(fmt(b)) ±\(tol)") }
}
func fmt(_ v: Double) -> String { v.isFinite ? String(format: "%.4f", v) : (v < 0 ? "-inf" : "inf") }
func section(_ s: String) { print("\n── \(s)") }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("soundmix-offline-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let sr = 48_000.0

/// Write a multichannel WAV where channel i holds a sine at a known amplitude.
func writeSource(channels: Int, seconds: Double, amplitude: (Int) -> Double,
                 frequency: ((Int) -> Double)? = nil,
                 name: String) throws -> URL {
    let url = tmp.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sr,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let total = Int(seconds * sr)
    let block = 4096
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
    var n = 0
    while n < total {
        let count = min(block, total - n)
        buf.frameLength = AVAudioFrameCount(count)
        for c in 0..<channels {
            let plane = buf.floatChannelData![c]
            let amp = amplitude(c)
            let freq = frequency?(c) ?? (110.0 * Double(c + 2))
            for f in 0..<count {
                plane[f] = Float(amp * sin(2 * .pi * freq * Double(n + f) / sr))
            }
        }
        try file.write(from: buf)
        n += count
    }
    return url
}

/// Read a stereo file back and report peak per channel plus frame count.
func analyse(_ url: URL) throws -> (peakL: Double, peakR: Double, frames: Int, channels: Int, rate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    var pl = 0.0, pr = 0.0, frames = 0
    while true {
        buf.frameLength = 0
        if file.framePosition >= file.length { break }
        do { try file.read(into: buf) } catch { break }
        let n = Int(buf.frameLength)
        if n == 0 { break }
        if let d = buf.floatChannelData {
            for f in 0..<n {
                pl = max(pl, abs(Double(d[0][f])))
                if format.channelCount > 1 { pr = max(pr, abs(Double(d[1][f]))) }
            }
        }
        frames += n
    }
    return (pl, pr, frames, Int(format.channelCount), format.sampleRate)
}

func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -.infinity }

section("Inspecting a source file")
let src16 = try! writeSource(channels: 16, seconds: 1.0,
                             amplitude: { _ in 0.25 }, name: "bed16.wav")
do {
    let info = try OfflineRenderer.inspect(src16)
    check(info.channels == 16, "channel count read", "\(info.channels)")
    near(info.sampleRate, sr, 1e-9, "sample rate read")
    near(info.duration, 1.0, 0.01, "duration read")
    check(info.suggestedLayout?.name == "9.1.6", "suggests 9.1.6 for a 16-channel file",
          info.suggestedLayout?.name ?? "nil")

    let src6 = try! writeSource(channels: 6, seconds: 0.2, amplitude: { _ in 0.1 }, name: "bed6.wav")
    let info6 = try OfflineRenderer.inspect(src6)
    check(info6.suggestedLayout?.name == "5.1", "suggests 5.1 for a 6-channel file",
          info6.suggestedLayout?.name ?? "nil")
}

section("Rendering reproduces the matrix exactly")
do {
    // Front left only, so the expected output is unambiguous.
    let src = try! writeSource(channels: 16, seconds: 0.5,
                               amplitude: { $0 == 0 ? 0.5 : 0 }, name: "frontleft.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference,
                                     headroomMode: .none, manualGainDB: 0)
    cfg.limiter = .init(enabled: false)
    let out = tmp.appendingPathComponent("fl-out.wav")
    let r = try OfflineRenderer().render(input: src, output: out, configuration: cfg, bitDepth: 32)
    let a = try analyse(out)
    check(a.channels == 2, "output is stereo", "\(a.channels)")
    near(a.rate, sr, 1e-9, "output keeps the sample rate")
    near(a.peakL, 0.5, 0.002, "front left arrives at unity on L")
    near(a.peakR, 0.0, 1e-4, "front left does not reach R")
    check(r.clippedSamples == 0, "no clipping", "\(r.clippedSamples)")
    print("       → rendered \(String(format: "%.2f", r.duration))s in \(String(format: "%.3f", r.renderTime))s (\(String(format: "%.0f", r.speedFactor))× real time)")

    // Centre must land at -3.01 dB on both.
    let srcC = try! writeSource(channels: 16, seconds: 0.5,
                                amplitude: { $0 == 2 ? 0.5 : 0 }, name: "centre.wav")
    let outC = tmp.appendingPathComponent("c-out.wav")
    _ = try OfflineRenderer().render(input: srcC, output: outC, configuration: cfg, bitDepth: 32)
    let ac = try analyse(outC)
    near(db(ac.peakL) - db(0.5), -3.0103, 0.05, "centre folds to L at −3.01 dB")
    near(db(ac.peakR) - db(0.5), -3.0103, 0.05, "centre folds to R at −3.01 dB")
}

section("Binaural rendering through the file path")
do {
    var profile = BinauralProfile.virtualSpeakers
    profile.lfe = LFESettings(mode: .off)
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference,
                                     headroomMode: .none, manualGainDB: 0)
    cfg.binaural = profile
    cfg.limiter = .init(enabled: false)

    // Every mapped channel has to arrive from the side it sits on. 4 kHz is
    // well above the head-shadow corner, so the level difference is the cue.
    let cases: [(BedChannel, String)] = [
        (.l, "front left"), (.r, "front right"), (.ls, "side surround left"),
        (.rs, "side surround right"), (.ltf, "top front left"), (.rtf, "top front right"),
        (.lrs, "rear surround left"), (.c, "centre"),
    ]
    for (ch, label) in cases {
        let src = try! writeSource(channels: 16, seconds: 0.25,
                                   amplitude: { $0 == ch.rawValue ? 0.5 : 0 },
                                   frequency: { _ in 4000 },
                                   name: "bin-\(ch.shortName).wav")
        let out = tmp.appendingPathComponent("bin-\(ch.shortName)-out.wav")
        _ = try OfflineRenderer().render(input: src, output: out, configuration: cfg, bitDepth: 32)
        let a = try analyse(out)
        let balance = db(a.peakL) - db(a.peakR)
        switch ch.side {
        case .left:  check(balance > 4, "\(label) arrives on the left", String(format: "%+.1f dB", balance))
        case .right: check(balance < -4, "\(label) arrives on the right", String(format: "%+.1f dB", balance))
        case .none:  check(abs(balance) < 0.2, "\(label) arrives centred", String(format: "%+.1f dB", balance))
        }
    }

    // The same file rendered twice must come out byte for byte identical.
    let src = try! writeSource(channels: 16, seconds: 0.5, amplitude: { _ in 0.2 },
                               name: "bin-all.wav")
    let first = tmp.appendingPathComponent("bin-all-1.wav")
    let second = tmp.appendingPathComponent("bin-all-2.wav")
    let r1 = try OfflineRenderer().render(input: src, output: first, configuration: cfg, bitDepth: 32)
    _ = try OfflineRenderer().render(input: src, output: second, configuration: cfg, bitDepth: 32)
    let d1 = try Data(contentsOf: first), d2 = try Data(contentsOf: second)
    check(d1 == d2, "the binaural render is deterministic", "\(d1.count) vs \(d2.count) bytes")
    print("       → binaural rendered \(String(format: "%.2f", r1.duration))s in \(String(format: "%.3f", r1.renderTime))s (\(String(format: "%.0f", r1.speedFactor))× real time)")

    // Untrimmed, fifteen correlated channels summing through the bank overshoot
    // full scale exactly as they do through a unity matrix — which is what the
    // automatic trim is for.
    check(r1.clippedSamples > 0, "an untrimmed fold overshoots on correlated content",
          "\(r1.clippedSamples)")
    var safe = cfg
    safe.headroomMode = .powerPreserving
    let outSafe = tmp.appendingPathComponent("bin-trimmed.wav")
    let rSafe = try OfflineRenderer().render(input: src, output: outSafe, configuration: safe, bitDepth: 32)
    let trimmed = try analyse(outSafe)
    let raw = try analyse(first)
    near(db(trimmed.peakL) - db(raw.peakL), safe.automaticTrimDB, 0.05,
         "the automatic trim reaches the rendered file")
    check(rSafe.clippedSamples == 0, "and the trimmed render does not clip",
          "\(rSafe.clippedSamples)")
}

section("Headroom and the limiter on a hostile file")
do {
    // Every channel at full scale at once — the case the original app clips on.
    let src = try! writeSource(channels: 16, seconds: 0.5,
                               amplitude: { _ in 0.95 }, name: "hostile.wav")

    var unprotected = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                             headroomMode: .none, manualGainDB: -9.5)
    unprotected.limiter = .init(enabled: false)
    let outRaw = tmp.appendingPathComponent("hostile-raw.wav")
    let rRaw = try OfflineRenderer().render(input: src, output: outRaw,
                                            configuration: unprotected, bitDepth: 32)
    check(rRaw.peakLeftDB > 0, "the original's −9.5 dB preamp overloads on this file",
          "peak \(fmt(rRaw.peakLeftDB)) dBFS")

    var safe = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                      headroomMode: .peakSafe, manualGainDB: 0)
    safe.limiter = .init(ceilingDB: -1, lookaheadMS: 2, releaseMS: 80, enabled: true)
    let outSafe = tmp.appendingPathComponent("hostile-safe.wav")
    let rSafe = try OfflineRenderer().render(input: src, output: outSafe,
                                             configuration: safe, bitDepth: 32)
    check(rSafe.peakLeftDB <= -0.85, "peak-safe trim plus limiter holds the ceiling",
          "peak \(fmt(rSafe.peakLeftDB)) dBFS")
    check(rSafe.clippedSamples == 0, "no clipped samples", "\(rSafe.clippedSamples)")
}

section("Layout and error handling")
do {
    let src6 = tmp.appendingPathComponent("bed6.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference)
    cfg.limiter = .init(enabled: false)
    var threw = false
    do {
        _ = try OfflineRenderer().render(input: src6,
                                         output: tmp.appendingPathComponent("bad.wav"),
                                         configuration: cfg)
    } catch { threw = true
        check("\(error)".contains("6") || (error as? LocalizedError)?.errorDescription?.contains("6") == true,
              "the error names the file's channel count",
              (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
    check(threw, "a 6-channel file against a 9.1.6 layout is refused")

    // The same file with a matching layout renders fine.
    cfg.layout = LayoutPreset.all.first { $0.name == "5.1" }!
    let out = tmp.appendingPathComponent("ok51.wav")
    let r = try OfflineRenderer().render(input: src6, output: out, configuration: cfg)
    check(r.frames > 0, "5.1 file renders against the 5.1 layout", "\(r.frames) frames")
    let a = try analyse(out)
    check(a.channels == 2 && a.frames > 0, "and produces a stereo file")

    var missing = false
    do { _ = try OfflineRenderer.inspect(tmp.appendingPathComponent("nope.wav")) }
    catch { missing = true }
    check(missing, "a missing file is reported rather than crashing")
}

section("Output bit depth")
do {
    let src = tmp.appendingPathComponent("bed16.wav")
    var cfg = ProcessorConfiguration(layout: .nativeBed, recipe: .reference)
    cfg.limiter = .init(enabled: false)
    for depth in [16, 24, 32] {
        let out = tmp.appendingPathComponent("depth\(depth).wav")
        _ = try OfflineRenderer().render(input: src, output: out, configuration: cfg, bitDepth: depth)
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path))?[.size] as? Int) ?? 0
        check(size > 1000, "\(depth)-bit output written", "\(size) bytes")
    }
}


section("Export safety and tail accounting")
do {
    let src = try writeSource(channels: 2, seconds: 0.1, amplitude: { _ in 0.2 }, name: "protected.wav")
    let original = try Data(contentsOf: src)
    let cfg = ProcessorConfiguration(layout: LayoutPreset.all.first { $0.requiredInputChannels == 2 }!, headroomMode: .none)
    let symlink = tmp.appendingPathComponent("alias.wav")
    let hardlink = tmp.appendingPathComponent("hardlink.wav")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: src)
    try FileManager.default.linkItem(at: src, to: hardlink)
    for output in [src, symlink, hardlink] {
        do {
            _ = try OfflineRenderer().render(input: src, output: output, configuration: cfg)
            check(false, "source alias rejected: \(output.lastPathComponent)")
        } catch OfflineRenderer.RenderError.sameFile {
            check(true, "source alias rejected: \(output.lastPathComponent)")
        }
        check(try Data(contentsOf: src) == original, "source bytes preserved")
    }
    let impulse = tmp.appendingPathComponent("last-frame.wav")
    do {
        let f = try AVAudioFile(forWriting: impulse, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 128)!
        b.frameLength = 128
        for c in 0..<2 { for n in 0..<128 { b.floatChannelData![c][n] = n == 127 ? 0.8 : 0 } }
        try f.write(from: b)
    }
    let output = tmp.appendingPathComponent("tail.wav")
    let result = try OfflineRenderer().render(input: impulse, output: output, configuration: cfg, bitDepth: 32)
    let actual = try analyse(output)
    near(result.peakLeftDB, db(actual.peakL), 0.001, "tail included in reported peak")
    check(result.frames == actual.frames, "reported frames match output")
    var long = cfg
    long.limiter.lookaheadMS = 120
    let extended = try OfflineRenderer().render(input: impulse, output: output, configuration: long, bitDepth: 32)
    check(extended.frames == (try analyse(output)).frames, "tail longer than one block is fully written")
    let renderer = OfflineRenderer()
    renderer.cancel()
    do {
        _ = try renderer.render(input: src, output: output, configuration: cfg)
        check(false, "cancellation before worker start is retained")
    } catch OfflineRenderer.RenderError.cancelled {
        check(true, "cancellation before worker start is retained")
    }
}

section("I/O failure publication")
do {
    let src = try writeSource(channels: 2, seconds: 4, amplitude: { _ in 0.2 }, name: "truncated.wav")
    let output = tmp.appendingPathComponent("keep-existing.wav")
    let original = Data("existing destination".utf8)
    try original.write(to: output)
    let cfg = ProcessorConfiguration(layout: LayoutPreset.all.first { $0.requiredInputChannels == 2 }!)
    var truncated = false
    do {
        _ = try OfflineRenderer().render(input: src, output: output, configuration: cfg) { _ in
            if !truncated {
                truncated = true
                let handle = try! FileHandle(forWritingTo: src)
                try! handle.truncate(atOffset: 4096)
                try! handle.close()
            }
        }
        check(false, "mid-render read failure propagates")
    } catch { check(true, "mid-render read failure propagates") }
    check(try Data(contentsOf: output) == original, "read failure preserves existing destination")
    let intact = try writeSource(channels: 2, seconds: 0.1, amplitude: { _ in 0.2 }, name: "intact.wav")
    let directory = tmp.appendingPathComponent("destination-directory.wav")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        _ = try OfflineRenderer().render(input: intact, output: directory, configuration: cfg)
        check(false, "output publication failure propagates")
    } catch { check(true, "output publication failure propagates") }
    let renderer = OfflineRenderer()
    do {
        _ = try renderer.render(input: intact, output: output, configuration: cfg) { _ in renderer.cancel() }
        check(false, "mid-render cancellation propagates")
    } catch OfflineRenderer.RenderError.cancelled { check(true, "mid-render cancellation propagates") }
    check(try Data(contentsOf: output) == original, "cancelled render preserves existing destination")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
    check(!leftovers.contains { $0.hasPrefix(".soundmix-") }, "failed render temporary files cleaned up")
}

section("Independent device clocks")
for ppm in [-200.0, 200.0] {
    let ring = FloatRingBuffer(frames: 4096, channels: 2, targetFrames: 960)
    var input = [Float](repeating: 0.25, count: 260)
    var output = [Float](repeating: 0, count: 256)
    var accumulated = 0.0
    var started = false, amplitudeError = 0.0
    // Five simulated minutes, including both faster and slower capture clocks.
    for _ in 0..<112500 {
        accumulated += 128 * (1 + ppm / 1_000_000)
        let produced = Int(accumulated); accumulated -= Double(produced)
        ring.write(&input, frames: produced)
        ring.readAdaptive(into: &output, frames: 128)
        if output[0] != 0 { started = true }
        if started { amplitudeError = max(amplitudeError, abs(Double(output[0]) - 0.25)) }
    }
    check(started, "clock bridge starts after prefill at \(ppm) ppm")
    check(ring.underruns == 0 && ring.overruns == 0, "no clock-drift dropouts at \(ppm) ppm")
    near(amplitudeError, 0, 0.00001, "clock bridge preserves DC gain")
    check((700...1200).contains(ring.framesAvailable), "clock bridge holds buffer occupancy")
}

section("Engine lifecycle without hardware")
do {
    // The realtime AUHAL path needs devices this suite does not have; what it
    // can verify is that the engine object is safe to construct, reconfigure,
    // and release when no stream was ever started.
    let engine = SoundMixEngine()
    check(engine.state == .stopped, "a fresh engine reports stopped")
    check(engine.captureCallbackCount == 0 && engine.captureOversizeCount == 0,
          "capture diagnostics start at zero")
    var config = ProcessorConfiguration()
    config.globalPEQ = PEQProfile(preampDB: 0, filters: [
        PEQFilter(frequency: 100, gainDB: 2, q: 1)
    ])
    // A queued configuration is adopted when the next block is processed; the
    // accessor must report what is actually rendering, not what is queued.
    engine.apply(config)
    check(engine.currentConfiguration != config,
          "a queued configuration is not live until a block is processed")
    var input = [Float](repeating: 0, count: 32 * 16)
    var output = [Float](repeating: 0, count: 32 * 2)
    engine.processor.process(input: &input, inputChannels: 16, frames: 32, output: &output)
    check(engine.currentConfiguration == config,
          "a processed block adopts the queued configuration")
    engine.stop()
    check(engine.state == .stopped, "stopping a never-started engine stays stopped")
    engine.processor.reset()
    check(engine.processor.configuration == config,
          "reset keeps the configuration")
}

// MARK: - PEQdB catalog

section("PEQdB catalog")

do {
    // Synthetic blob in the site layout: Float32 scale, Float32 offset,
    // 384 Int16 samples on the 20 Hz to 20 kHz log grid.
    func rec(scale: Float, offset: Float, sample: Int16) -> Data {
        var d = Data()
        withUnsafeBytes(of: scale) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: offset) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: sample) { d.append(contentsOf: $0) }
        for i in 1..<384 {
            let s = i % 2 == 0 ? sample : Int16(-sample)
            withUnsafeBytes(of: s) { d.append(contentsOf: $0) }
        }
        return d
    }
    var bin = rec(scale: 0.25, offset: 1.0, sample: 40)   // 0: L
    bin.append(rec(scale: 0.25, offset: 1.0, sample: 40)) // 1: R pair
    bin.append(rec(scale: 0.5, offset: 2.0, sample: -10)) // 2: single

    let indexText = "{\"IE\":{\"Super Review\":{\"MOONDROP CHU\":{\"stock\":[0,2]}}},\"OE\":{\"Oratory1990\":{\"SENNHEISER HD600\":{\"\":[2,1]}}}}"
    let cache = tmp.appendingPathComponent("peqdb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try indexText.data(using: .utf8)!.write(to: cache.appendingPathComponent("catalog.json"))
    try bin.write(to: cache.appendingPathComponent("graph-data.bin"))

    let catalog = PEQDBCatalog(cacheDirectory: cache)
    try catalog.loadCached()
    check(catalog.isLoaded, "catalog loads from cache")
    check(catalog.brands.count == 2, "two brands parsed", "got \(catalog.brands.count)")

    let chu = catalog.brands.flatMap { $0.models }.first { $0.name == "MOONDROP CHU" }
    check(chu != nil, "MOONDROP CHU present")
    check(chu?.variants.first?.channelCount == 2, "CHU is a two-channel pair")

    if let chu {
        let pair = catalog.response(for: chu.variants[0], model: chu, into: .left)
        check(pair.left != nil && pair.right != nil, "pair fills both ears")
        check(pair.left?.points.count == 384, "384 points per curve")
        check(pair.left!.points.allSatisfy { $0.db.isFinite }, "pair curve finite")

        let mirrored = catalog.response(for: chu.variants[0], model: chu, into: .right)
        check(mirrored.left != nil && mirrored.right != nil, "pair into either ear fills both")
    }

    let hd600 = catalog.brands.flatMap { $0.models }.first { $0.name == "SENNHEISER HD600" }
    check(hd600?.variants.first?.name == "Standard", "unnamed variant becomes Standard")
    if let hd600 {
        let single = catalog.response(for: hd600.variants[0], model: hd600, into: .right)
        check(single.right != nil && single.left == nil, "single-channel entry goes to chosen ear")
    }

    let hits = catalog.searchModels(matching: "chu")
    check(hits.contains { $0.name == "MOONDROP CHU" }, "search finds CHU case-insensitively")

    let page = "<script>window.__INDEX__ = " + indexText + ";</script>"
    if let extracted = PEQDBIndexParser.extractIndex(html: page) {
        let brands = try PEQDBIndexParser.parseCatalog(data: extracted)
        check(brands.count == 2, "index extracted from studio HTML")
    } else {
        check(false, "index extracted from studio HTML")
    }
} catch {
    failures += 1
    print("  FAIL PEQdB catalog test block: \(error)")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("Offline rendering verified.")
