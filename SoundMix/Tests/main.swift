import Foundation

// Minimal harness so the DSP can be verified without Xcode or a test rig.
var failures = 0, checks = 0

func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if ok { print("  ok   \(label)") }
    else { failures += 1; print("  FAIL \(label) \(detail())") }
}

func near(_ a: Double, _ b: Double, _ tol: Double, _ label: String) {
    checks += 1
    if abs(a - b) <= tol { print("  ok   \(label)  (\(fmt(a)))") }
    else { failures += 1; print("  FAIL \(label): got \(fmt(a)) expected \(fmt(b)) ±\(tol)") }
}

func fmt(_ v: Double) -> String {
    v.isFinite ? String(format: "%.6f", v) : (v < 0 ? "-inf" : "inf")
}

func section(_ name: String) { print("\n── \(name)") }

let sr = 48_000.0

// MARK: - Parity with the original binary

section("Matrix parity with the shipped renderer")
do {
    let m = MatrixRecipe.parity.matrix()
    near(m[.l].left, 1.0, 1e-12, "FL → L is unity")
    near(m[.l].right, 0.0, 1e-12, "FL → R is silent")
    near(m[.r].right, 1.0, 1e-12, "FR → R is unity")
    near(m[.c].left, 0.70710678, 1e-7, "FC → L matches 0.70710678")
    near(m[.c].right, 0.70710678, 1e-7, "FC → R matches 0.70710678")
    // The constant recovered from _main at 0x100002780 (0x40021DFDD6042E0D).
    near(m[.lfe].left, 2.26464431, 1e-6, "LFE coefficient matches the binary")
    near(m[.lfe].right, 2.26464431, 1e-6, "LFE coefficient is the same on R")
    for ch in [BedChannel.ls, .lrs, .lw, .ltf, .ltm, .ltr] {
        near(m[ch].left, 1.0, 1e-12, "\(ch.shortName) → L is unity (original behaviour)")
        near(m[ch].right, 0.0, 1e-12, "\(ch.shortName) → R is silent")
    }
    for ch in [BedChannel.rs, .rrs, .rw, .rtf, .rtm, .rtr] {
        near(m[ch].right, 1.0, 1e-12, "\(ch.shortName) → R is unity (original behaviour)")
    }
}

section("Headroom analysis exposes the original's overload")
do {
    let m = MatrixRecipe.parity.matrix()
    // 7 left-side channels at 1.0, centre at 0.7071, LFE at 2.2646.
    near(m.worstCasePeakGain, 7 + 0.70710678 + 2.26464431, 1e-6, "parity worst-case L1 gain")
    check(m.worstCasePeakGainDB > 19.5 && m.worstCasePeakGainDB < 20.5,
          "parity can reach ~+20 dB", "got \(fmt(m.worstCasePeakGainDB)) dB")
    // The original ships a -9.5 dB preamp default, which does not cover this.
    check(m.worstCasePeakGainDB > 9.5,
          "the original's -9.5 dB default cannot prevent clipping")

    let ref = MatrixRecipe.reference.matrix()
    check(ref.worstCasePeakGainDB < m.worstCasePeakGainDB,
          "reference fold has less worst-case gain than parity",
          "\(fmt(ref.worstCasePeakGainDB)) vs \(fmt(m.worstCasePeakGainDB))")
}

section("Automatic trim actually removes the overload")
do {
    for mode in [HeadroomMode.peakSafe, .powerPreserving] {
        var cfg = ProcessorConfiguration()
        cfg.recipe = .parity
        cfg.layout = .nativeBed
        cfg.headroomMode = mode
        let trimmed = cfg.effectiveMatrix.scaled(by: SoundMixMatrix.linear(cfg.automaticTrimDB))
        switch mode {
        case .peakSafe:
            near(trimmed.worstCasePeakGain, 1.0, 1e-9, "peak-safe trim lands exactly at unity L1")
        case .powerPreserving:
            near(trimmed.uncorrelatedGain, 1.0, 1e-9, "power-preserving trim lands at unity L2")
        case .none: break
        }
    }
}

section("Layout restriction changes the trim")
do {
    var a = ProcessorConfiguration(); a.recipe = .parity; a.layout = .nativeBed
    var b = ProcessorConfiguration(); b.recipe = .parity
    b.layout = LayoutPreset.all.first { $0.name == "5.1" }!
    a.headroomMode = .peakSafe; b.headroomMode = .peakSafe
    check(b.automaticTrimDB > a.automaticTrimDB,
          "a 5.1 source needs less trim than a full 9.1.6 bed",
          "5.1 \(fmt(b.automaticTrimDB)) dB vs 9.1.6 \(fmt(a.automaticTrimDB)) dB")
}

// MARK: - Filters

section("Butterworth low-pass design")
do {
    let fc = 125.0
    let c = BiquadDesign.butterworthLowPass(frequency: fc, order: 4, sampleRate: sr)
    check(c.sections.count == 2, "4th order is two biquads", "got \(c.sections.count)")
    near(c.magnitudeDB(at: fc, sampleRate: sr), -3.0103, 0.05, "−3 dB at the cutoff")
    near(c.magnitudeDB(at: fc / 8, sampleRate: sr), 0.0, 0.05, "flat three octaves below")
    // 24 dB/octave: one octave up from cutoff is about −24 dB below the −3 dB point.
    let oneOctave = c.magnitudeDB(at: fc * 2, sampleRate: sr)
    near(oneOctave, -24.1, 0.6, "≈ −24 dB one octave above the cutoff")
    let twoOctaves = c.magnitudeDB(at: fc * 4, sampleRate: sr)
    near(twoOctaves - oneOctave, -24.0, 0.8, "slope is 24 dB/octave")

    for order in [1, 2, 3, 5, 6, 8] {
        let cc = BiquadDesign.butterworthLowPass(frequency: 200, order: order, sampleRate: sr)
        near(cc.magnitudeDB(at: 200, sampleRate: sr), -3.0103, 0.1, "order \(order) is −3 dB at cutoff")
        near(cc.magnitudeDB(at: 10, sampleRate: sr), 0.0, 0.05, "order \(order) is flat in the passband")
    }

    let tau = c.groupDelay(at: 0, sampleRate: sr)
    check(tau > 0 && tau < sr, "DC group delay is sane", "\(fmt(tau)) samples")
    print("       → 125 Hz / 4th order DC group delay = \(fmt(tau)) samples (\(fmt(tau / sr * 1000)) ms)")
}

section("Peaking and shelving filters")
do {
    let pk = BiquadDesign.peaking(frequency: 1000, q: 1.41, gainDB: 6, sampleRate: sr)
    near(pk.magnitudeDB(at: 1000, sampleRate: sr), 6.0, 0.02, "peaking hits its gain at Fc")
    near(pk.magnitudeDB(at: 20, sampleRate: sr), 0.0, 0.1, "peaking is flat far below")
    let ls = BiquadDesign.lowShelf(frequency: 200, q: 0.707, gainDB: -6, sampleRate: sr)
    near(ls.magnitudeDB(at: 10, sampleRate: sr), -6.0, 0.2, "low shelf reaches its gain at DC")
    near(ls.magnitudeDB(at: 10_000, sampleRate: sr), 0.0, 0.2, "low shelf is flat up top")
    let hs = BiquadDesign.highShelf(frequency: 4000, q: 0.707, gainDB: 4, sampleRate: sr)
    near(hs.magnitudeDB(at: 20_000, sampleRate: sr), 4.0, 0.4, "high shelf reaches its gain up top")
    near(hs.magnitudeDB(at: 50, sampleRate: sr), 0.0, 0.2, "high shelf is flat down low")
}

// MARK: - PEQ file compatibility

section("REW / Equalizer APO parsing")
do {
    let text = """
    Preamp: -6.3 dB
    Filter 1: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41
    Filter 2: ON LSC Fc 105 Hz Gain 4.5 dB Q 0.70
    Filter 3: OFF HS Fc 10000 Hz Gain -2 dB Q 0.71
    Filter 4: ON None
    # a comment
    """
    let doc = APOParser.parse(text)
    let p = doc.firstProfile
    near(p.preampDB, -6.3, 1e-9, "preamp parsed")
    check(p.filters.count == 3, "three filters parsed", "got \(p.filters.count)")
    check(p.activeFilterCount == 2, "one filter is OFF", "active \(p.activeFilterCount)")
    check(p.filters[0].kind == .peaking && p.filters[0].frequency == 1000, "PK parsed")
    check(p.filters[1].kind == .lowShelf && p.filters[1].gainDB == 4.5, "LSC parsed")
    check(p.filters[2].kind == .highShelf && !p.filters[2].enabled, "OFF HS parsed")
    near(p.magnitudeDB(at: 1000, sampleRate: sr), -6.3 - 3.0, 0.25, "response matches preamp + filter")

    let stereo = """
    Preamp: -2 dB l
    Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1 l
    Preamp: -4 dB r
    Filter 1: ON PK Fc 500 Hz Gain -3 dB Q 1 r
    """
    let sdoc = APOParser.parse(stereo)
    near(sdoc.profile(forChannel: 0).preampDB, -2, 1e-9, "left channel preamp")
    near(sdoc.profile(forChannel: 1).preampDB, -4, 1e-9, "right channel preamp")
    near(sdoc.profile(forChannel: 0).filters[0].gainDB, 3, 1e-9, "left filter gain")
    near(sdoc.profile(forChannel: 1).filters[0].gainDB, -3, 1e-9, "right filter gain")
}

// MARK: - Limiter

section("True-peak limiter holds its ceiling")
do {
    for ceiling in [-1.0, -0.3, -3.0] {
        let lim = TruePeakLimiter(sampleRate: sr,
                                  settings: .init(ceilingDB: ceiling, lookaheadMS: 2, releaseMS: 60))
        var worst = -200.0
        // A loud sine well over full scale, plus a hard transient burst.
        for n in 0..<24_000 {
            let t = Double(n) / sr
            var drive = 2.0 * sin(2 * .pi * 440 * t)
            if n % 6000 == 0 { drive = 4.0 }
            var l = drive, r = drive * 0.8
            lim.process(&l, &r)
            if n > 500 {   // let the look-ahead prime
                worst = max(worst, 20 * log10(max(abs(l), abs(r), 1e-9)))
            }
        }
        check(worst <= ceiling + 0.15,
              "ceiling \(fmt(ceiling)) dB respected", "peak reached \(fmt(worst)) dB")
    }

    let lim = TruePeakLimiter(sampleRate: sr, settings: .init(ceilingDB: -1, lookaheadMS: 2))
    var quietMax = 0.0
    for n in 0..<4800 {
        var l = 0.1 * sin(2 * .pi * 100 * Double(n) / sr), r = l
        lim.process(&l, &r)
        if n > 300 { quietMax = max(quietMax, abs(l)) }
    }
    near(quietMax, 0.1, 0.002, "quiet material passes through untouched")
}

// MARK: - End to end

section("Processor end to end")
do {
    let frames = 512
    let channels = 16

    func run(_ cfg: ProcessorConfiguration, fill: (Int, Int) -> Float) -> (peak: Double, lastL: Double, lastR: Double) {
        let proc = SoundMixProcessor()
        proc.applyNow(cfg)
        proc.prepare(sampleRate: sr)
        proc.applyNow(cfg)
        var input = [Float](repeating: 0, count: frames * channels)
        var output = [Float](repeating: 0, count: frames * 2)
        var peak = 0.0, lastL = 0.0, lastR = 0.0
        for block in 0..<20 {
            for f in 0..<frames {
                for c in 0..<channels { input[f * channels + c] = fill(block * frames + f, c) }
            }
            input.withUnsafeBufferPointer { inPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    proc.process(input: inPtr.baseAddress!, inputChannels: channels,
                                 frames: frames, output: outPtr.baseAddress!)
                }
            }
            if block > 2 {
                for f in 0..<frames {
                    peak = max(peak, Double(abs(output[f * 2])), Double(abs(output[f * 2 + 1])))
                }
            }
            lastL = Double(output[(frames - 1) * 2])
            lastR = Double(output[(frames - 1) * 2 + 1])
        }
        return (peak, lastL, lastR)
    }

    // Worst case the original cannot survive: full scale on every bed channel.
    var parity = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                        headroomMode: .peakSafe, manualGainDB: 0)
    parity.limiter = .init(ceilingDB: -1, lookaheadMS: 2, enabled: true)
    let hostile = run(parity) { n, _ in Float(0.95 * sin(2 * .pi * 220 * Double(n) / sr)) }
    check(hostile.peak <= pow(10, -1.0 / 20) + 0.01,
          "full-scale 9.1.6 bed stays under the −1 dBTP ceiling",
          "peak \(fmt(20 * log10(hostile.peak))) dB")

    // The same hostile input without any protection, to show what the original does.
    var raw = ProcessorConfiguration(layout: .nativeBed, recipe: .parity,
                                     headroomMode: .none, manualGainDB: -9.5)
    raw.limiter = .init(enabled: false)
    let unprotected = run(raw) { n, _ in Float(0.95 * sin(2 * .pi * 220 * Double(n) / sr)) }
    check(unprotected.peak > 1.0,
          "the original's −9.5 dB preamp alone still overloads",
          "peak \(fmt(20 * log10(unprotected.peak))) dBFS")

    // Routing: a DC-ish signal on device channel 1 only must land on L only.
    var routing = ProcessorConfiguration(layout: .nativeBed, recipe: .reference,
                                         headroomMode: .none, manualGainDB: 0)
    routing.limiter = .init(enabled: false)
    let onlyLeft = run(routing) { _, c in c == 0 ? 0.5 : 0 }
    near(onlyLeft.lastL, 0.5, 1e-6, "channel 1 reaches L at unity")
    near(onlyLeft.lastR, 0.0, 1e-9, "channel 1 does not reach R")

    // Swap must exchange the outputs.
    var swapped = routing
    swapped.swapOutputs = true
    let sw = run(swapped) { _, c in c == 0 ? 0.5 : 0 }
    near(sw.lastR, 0.5, 1e-6, "swap moves channel 1 to R")
    near(sw.lastL, 0.0, 1e-9, "swap clears L")

    // Centre must arrive at −3.01 dB on both outputs.
    let centre = run(routing) { _, c in c == 2 ? 0.5 : 0 }
    near(centre.lastL, 0.5 * 0.70710678, 1e-6, "centre → L at −3.01 dB")
    near(centre.lastR, 0.5 * 0.70710678, 1e-6, "centre → R at −3.01 dB")

    // An unmapped bed slot must be silent.
    var stereoOnly = routing
    stereoOnly.layout = LayoutPreset.all.first { $0.name == "2.0 stereo" }!
    let muted = run(stereoOnly) { _, c in c == 4 ? 0.9 : 0 }   // device ch 5 = Ls, unmapped in 2.0
    near(muted.lastL, 0.0, 1e-9, "unmapped channel is silent on L")
    near(muted.lastR, 0.0, 1e-9, "unmapped channel is silent on R")
}

section("Layout presets are well formed")
do {
    for p in LayoutPreset.all {
        check(p.map.count == 16, "\(p.name) has 16 slots")
        let used = p.map.filter { $0 > 0 }
        check(Set(used).count == used.count, "\(p.name) maps each device channel at most once")
        check(p.requiredInputChannels <= 16, "\(p.name) needs ≤ 16 device channels")
    }
    let f714 = LayoutPreset.all.first { $0.name == "7.1.4" }!
    check(f714.activeChannels.contains(.ltr) && f714.activeChannels.contains(.rtr),
          "7.1.4 uses top-rear, not top-middle (the original mapped these to Ltm/Rtm)")
}

section("EQ profile library")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-eq-tests-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    check(lib.profiles.isEmpty, "a fresh library is empty")

    let apo = """
    Preamp: -3.0 dB
    Filter 1: ON PK Fc 60 Hz Gain 4 dB Q 0.9
    Filter 2: ON HSC Fc 8000 Hz Gain -2.5 dB Q 0.7
    """
    let saved = try! lib.save(EQProfile(name: "Desk", globalText: apo))
    check(lib.profiles.count == 1, "saving adds one profile")
    check(lib.profile(named: "Desk") != nil, "profile is findable by name")
    check(saved.globalProfile.activeFilterCount == 2, "profile exposes its parsed filters")

    // One file per profile, on disk, readable.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
    check(files.count == 1 && files[0].hasSuffix(".json"), "one JSON file per profile", "\(files)")

    // Reload from disk must reproduce it.
    let lib2 = EQProfileLibrary(directory: tmp)
    check(lib2.profiles.count == 1 && lib2.profiles[0].name == "Desk",
          "profiles survive a reload from disk")

    // Peak boost drives the headroom warning.
    near(saved.peakBoostDB(sampleRate: sr), 1.0, 0.6, "peak boost accounts for preamp plus filter")

    // Duplicate never collides.
    let copy = try! lib.duplicate(saved)
    check(copy.name == "Desk copy", "duplicate gets a free name", copy.name)
    check(copy.id != saved.id, "duplicate gets a new id")
    let copy2 = try! lib.duplicate(saved)
    check(copy2.name == "Desk copy 2", "second duplicate increments", copy2.name)

    // Export → import round trip.
    let data = try! lib.exportData(lib.profiles)
    let target = EQProfileLibrary(directory: tmp.appendingPathComponent("other"))
    let imported = try! target.importData(data, fallbackName: "bundle")
    check(imported.count == 3, "bundle round-trips every profile", "got \(imported.count)")
    check(target.profile(named: "Desk")?.globalText == apo, "profile text survives the round trip")
    check(imported.allSatisfy { p in !lib.profiles.contains { $0.id == p.id } },
          "import always assigns fresh ids so nothing is overwritten")

    // Importing the same bundle twice must not clobber the first copy.
    let again = try! target.importData(data, fallbackName: "bundle")
    check(target.profiles.count == 6, "re-importing adds rather than replaces", "\(target.profiles.count)")
    check(again.contains { $0.name == "Desk 2" }, "a colliding name is numbered",
          again.map(\.name).joined(separator: ","))

    // Raw APO text is accepted too.
    let fromText = try! target.importData(Data(apo.utf8), fallbackName: "Harman")
    check(fromText.count == 1 && fromText[0].name == "Harman", "APO text imports as a profile")
    check(fromText[0].globalProfile.activeFilterCount == 2, "imported APO keeps its filters")

    // Rubbish is rejected rather than silently creating an empty profile.
    var rejected = false
    do { _ = try target.importData(Data([0xFF, 0xFE, 0x00]), fallbackName: "junk") }
    catch { rejected = true }
    check(rejected, "unreadable input is rejected")

    // APO text output round-trips through the parser.
    let text = saved.globalProfile.apoText()
    let reparsed = APOParser.parse(text).firstProfile
    near(reparsed.preampDB, -3.0, 1e-6, "exported APO keeps the preamp")
    check(reparsed.activeFilterCount == 2, "exported APO keeps both filters")
    near(reparsed.filters[0].frequency, 60, 1e-6, "exported APO keeps Fc")
    near(reparsed.filters[1].gainDB, -2.5, 1e-6, "exported APO keeps gain")

    try! lib.delete(saved)
    check(lib.profile(named: "Desk") == nil, "delete removes the profile")
}

section("Earphone measurement files")
do {
    // AutoEQ / oratory1990 style CSV with a header.
    let csv = """
    frequency,raw
    20.0,6.2
    50,5.0
    100,3.0
    200,1.0
    500,0.0
    1000,-1.0
    2000,2.0
    5000,-4.0
    10000,-8.0
    20000,-12.0
    """
    guard let m = FrequencyResponse.parse(csv, name: "Test IEM") else {
        check(false, "CSV measurement parses"); fatalError("parse failed")
    }
    check(m.points.count == 10, "every data row parsed", "got \(m.points.count)")
    near(m.range.low, 20, 1e-9, "lowest frequency")
    near(m.range.high, 20_000, 1e-9, "highest frequency")
    near(m.magnitudeDB(at: 1000), -1.0, 1e-9, "exact point returns its value")
    // Log-midpoint between 100 Hz (3 dB) and 200 Hz (1 dB) is ~141 Hz → 2 dB.
    near(m.magnitudeDB(at: (100 * 200).squareRoot()), 2.0, 1e-6, "interpolates in log frequency")
    near(m.magnitudeDB(at: 5), 6.2, 1e-9, "holds the endpoint below the measured range")
    near(m.magnitudeDB(at: 40_000), -12.0, 1e-9, "holds the endpoint above the measured range")

    // Whitespace and tab separated, with comments, must parse the same way.
    let txt = """
    # Generated by something
    * another comment style
    20.0\t6.2
    50 5.0
    100;3.0
    200 1.0
    500 0.0
    1000 -1.0
    2000 2.0
    5000 -4.0
    10000 -8.0
    20000 -12.0
    """
    let m2 = FrequencyResponse.parse(txt, name: "Mixed")
    check(m2 != nil && m2!.points.count == 10, "tab, space, semicolon and comments all handled",
          "got \(m2?.points.count ?? -1)")

    // Normalisation anchors the arbitrary absolute level.
    let norm = m.normalized(low: 200, high: 2_000)
    let mean = (0.5 * log(500.0 / 200) - 0.5 * log(1000.0 / 500)
                + 0.5 * log(2000.0 / 1000)) / log(10)
    near(norm.magnitudeDB(at: 500), 0.0 - mean, 1e-9, "normalisation subtracts the band mean")
    check(abs(norm.magnitudeDB(at: 1000) - (-1.0 - mean)) < 1e-9, "normalisation shifts the whole curve")

    // A flat EQ leaves the measurement alone.
    let flat = PEQProfile.flat.cascade(sampleRate: sr)
    let untouched = m.corrected(by: flat, sampleRate: sr)
    near(untouched.first(where: { $0.hz > 990 && $0.hz < 1010 })?.db ?? 99,
         m.magnitudeDB(at: untouched.first(where: { $0.hz > 990 && $0.hz < 1010 })!.hz),
         1e-6, "flat EQ leaves the curve unchanged")

    // A corrective filter must reduce the deviation it targets.
    let fix = PEQProfile(preampDB: 0, filters: [
        PEQFilter(kind: .peaking, frequency: 5000, gainDB: 4, q: 1.0),
    ])
    let corrected = m.corrected(by: fix.cascade(sampleRate: sr), sampleRate: sr)
    let before = m.magnitudeDB(at: 5000)
    let after = corrected.min(by: { abs($0.hz - 5000) < abs($1.hz - 5000) })!.db
    check(after > before, "a +4 dB filter lifts the dip at 5 kHz",
          "before \(fmt(before)) after \(fmt(after))")
    near(after - before, 4.0, 0.3, "the lift matches the filter gain")

    // Rubbish must be rejected, not turned into an empty curve.
    check(FrequencyResponse.parse("hello\nworld\n", name: "junk") == nil,
          "non-numeric text is rejected")
    check(FrequencyResponse.parse("20 1\n30 2\n", name: "tiny") == nil,
          "too few points is rejected")

    // The measurement travels with its EQ profile.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-fr-tests-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let withCurve = try! lib.save(EQProfile(name: "IEM", globalText: "Preamp: -2 dB", measurementLeft: m))
    check(withCurve.summary.contains("measured"), "a paired profile says so in its summary",
          withCurve.summary)
    let reloaded = EQProfileLibrary(directory: tmp).profiles.first
    check(reloaded?.measurementLeft?.points.count == 10, "measurement survives save and reload")
    near(reloaded?.measurementLeft?.magnitudeDB(at: 2000) ?? 99, 2.0, 1e-9, "its values survive too")

    // And through an export/import round trip.
    let data = try! lib.exportData(lib.profiles)
    let target = EQProfileLibrary(directory: tmp.appendingPathComponent("out"))
    let back = try! target.importData(data, fallbackName: "x")
    check(back.first?.measurementLeft?.points.count == 10, "measurement survives export and import")

    // Profiles saved before measurements existed must still load.
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","name":"Legacy","notes":"","globalText":"Preamp: -1 dB",
     "speakerText":"","created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z"}
    """.utf8)
    let legacyImported = try? target.importData(legacy, fallbackName: "legacy")
    check(legacyImported?.first?.measurementLeft == nil, "a profile without a measurement still loads")
    check(legacyImported?.first?.name == "Legacy", "and keeps its name")
}

section("Per-ear measurements and target curves")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dmx-ears-\(UUID().uuidString)")
    let lib = EQProfileLibrary(directory: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // A three-column export fills both ears at once.
    let pairText = """
    freq,L,R
    20,6.0,5.0
    50,4.0,3.5
    100,2.0,1.5
    200,1.0,0.5
    500,0.0,0.0
    1000,-1.0,-1.5
    2000,2.0,1.0
    5000,-4.0,-5.0
    10000,-8.0,-9.0
    20000,-12.0,-13.0
    """
    guard let pair = FrequencyResponse.parsePair(pairText, name: "IEM") else {
        check(false, "three-column file parses as a pair"); fatalError("no pair")
    }
    check(pair.left.points.count == 10 && pair.right.points.count == 10,
          "both ears parsed", "\(pair.left.points.count)/\(pair.right.points.count)")
    near(pair.left.magnitudeDB(at: 1000), -1.0, 1e-9, "left column read")
    near(pair.right.magnitudeDB(at: 1000), -1.5, 1e-9, "right column read")
    check(pair.left.name.hasSuffix("L") && pair.right.name.hasSuffix("R"),
          "the ears are named", "\(pair.left.name) / \(pair.right.name)")

    // A third column that is phase must NOT be read as the right ear.
    // This is the shape that actually slipped through: values sweeping far
    // beyond any level curve.
    var phaseText = "frequency,raw,phase\n"
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        let raw = 3.0 * sin(Double(i) / 4)
        let phase = 180.0 * sin(Double(i) / 2) + (i % 7 == 0 ? 120 : 0)
        phaseText += "\(hz),\(raw),\(phase)\n"
    }
    check(FrequencyResponse.parsePair(phaseText, name: "phase") == nil,
          "a phase column is rejected as a right ear")
    check(FrequencyResponse.parse(phaseText, name: "phase") != nil,
          "the same file still parses as a single curve")

    // Even without a header, wild values are refused.
    var headerless = ""
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        headerless += "\(hz),\(3.0 * sin(Double(i) / 4)),\(170.0 * sin(Double(i) / 2))\n"
    }
    check(FrequencyResponse.parsePair(headerless, name: "nohdr") == nil,
          "a headerless third column that swings wildly is refused")

    // A genuine pair without a header is still accepted.
    var realPair = ""
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        let l = 3.0 * sin(Double(i) / 4)
        realPair += "\(hz),\(l),\(l + 1.2)\n"
    }
    check(FrequencyResponse.parsePair(realPair, name: "real") != nil,
          "two ears that track each other are accepted without a header")

    // And a header naming the ears is believed even when they differ a lot.
    var labelled = "frequency,L,R\n"
    for i in 0..<60 {
        let hz = 20.0 * pow(10, Double(i) / 60 * 3)
        labelled += "\(hz),\(3.0 * sin(Double(i) / 4)),\(3.0 * sin(Double(i) / 4) - 11)\n"
    }
    check(FrequencyResponse.parsePair(labelled, name: "labelled") != nil,
          "a header naming L and R is trusted")

    // A two-column file must NOT be mistaken for a pair.
    let mono = "20,6.0\n50,4.0\n100,2.0\n200,1.0\n500,0.0\n1000,-1.0\n2000,2.0\n5000,-4.0\n10000,-8.0"
    check(FrequencyResponse.parsePair(mono, name: "mono") == nil,
          "a two-column file is not treated as a pair")
    check(FrequencyResponse.parse(mono, name: "mono") != nil,
          "but it still parses as a single curve")

    // Both ears and a target survive a save/reload.
    let target = FrequencyResponse.parse(mono, name: "JM-1")!
    let saved = try! lib.save(EQProfile(name: "IEM + target",
                                   globalText: "Preamp: -3 dB",
                                   measurementLeft: pair.left,
                                   measurementRight: pair.right,
                                   target: target))
    check(saved.hasMeasurement, "profile reports a measurement")
    check(saved.summary.contains("measured L+R"), "summary names both ears", saved.summary)
    check(saved.summary.contains("vs JM-1"), "summary names the target", saved.summary)

    let reloaded = EQProfileLibrary(directory: tmp).profiles.first
    near(reloaded?.measurementLeft?.magnitudeDB(at: 2000) ?? 99, 2.0, 1e-9, "left ear reloads")
    near(reloaded?.measurementRight?.magnitudeDB(at: 2000) ?? 99, 1.0, 1e-9, "right ear reloads")
    check(reloaded?.target?.name == "JM-1", "target reloads", reloaded?.target?.name ?? "nil")

    // One ear alone is allowed.
    let oneEar = try! lib.save(EQProfile(name: "One ear", measurementLeft: pair.left))
    check(oneEar.hasMeasurement && oneEar.measurementRight == nil, "a single ear is valid")
    check(oneEar.summary.contains("one ear"), "summary says so", oneEar.summary)
    check(oneEar.anyMeasurement != nil, "anyMeasurement falls back to whichever side exists")

    // Profiles written before the split used a single `measurement` key.
    let legacy = Data("""
    {"id":"\(UUID().uuidString)","name":"Legacy IEM","notes":"","globalText":"",
     "speakerText":"","created":"2026-01-01T00:00:00Z","modified":"2026-01-01T00:00:00Z",
     "measurement":{"name":"Old curve","points":[
       {"hz":20,"db":6},{"hz":50,"db":4},{"hz":100,"db":2},{"hz":200,"db":1},
       {"hz":500,"db":0},{"hz":1000,"db":-1},{"hz":2000,"db":2},{"hz":5000,"db":-4},
       {"hz":10000,"db":-8},{"hz":20000,"db":-12}]}}
    """.utf8)
    let migrated = try! lib.importData(legacy, fallbackName: "legacy")
    check(migrated.first?.measurementLeft?.name == "Old curve",
          "a legacy single measurement migrates to the left ear",
          migrated.first?.measurementLeft?.name ?? "nil")
    check(migrated.first?.measurementRight == nil, "and leaves the right ear empty")
    near(migrated.first?.measurementLeft?.magnitudeDB(at: 1000) ?? 99, -1.0, 1e-9,
         "the migrated curve keeps its values")

    // Difference against a target is what the error view draws.
    let flat = FrequencyResponse(name: "flat", points: (0...20).map {
        .init(hz: 20 * pow(10, Double($0) / 20 * 3), db: 0)
    })
    let diff = pair.left.difference(from: flat)
    check(!diff.isEmpty, "difference produces a curve", "\(diff.count) points")
    let at1k = diff.min { abs($0.hz - 1000) < abs($1.hz - 1000) }!
    near(at1k.db, pair.left.magnitudeDB(at: at1k.hz), 1e-9,
         "difference from a flat target equals the curve itself")

    // A perfect correction reads as zero error.
    let selfDiff = pair.left.difference(from: pair.left)
    check(selfDiff.allSatisfy { abs($0.db) < 1e-9 }, "a curve minus itself is zero everywhere")
}

section("Response plot normalization and coverage")
do {
    let sparse = FrequencyResponse(name: "Slope", points: [
        .init(hz: 20, db: -10), .init(hz: 200, db: 0),
        .init(hz: 1000, db: 10 * log10(5)), .init(hz: 2000, db: 10),
        .init(hz: 20000, db: 20)])
    let result = FrequencyResponse(name: "Flat EQ", points: sparse.corrected(
        by: PEQProfile.flat.cascade(sampleRate: 48000), sampleRate: 48000))
    near(result.normalized().magnitudeDB(at: 1000),
         sparse.normalized().magnitudeDB(at: 1000), 1e-9,
         "flat EQ preserves normalized measurement level")
    let dense = FrequencyResponse(name: "Dense", points: sparse.sampled(count: 1001))
    near(dense.normalized().magnitudeDB(at: 1000), sparse.normalized().magnitudeDB(at: 1000),
         1e-9, "normalization is independent of sample density")
    let partial = FrequencyResponse(name: "Partial", points: [
        .init(hz: 100, db: 3), .init(hz: 10000, db: 3)])
    let reference = FrequencyResponse(name: "Target", points: [
        .init(hz: 200, db: 1), .init(hz: 15000, db: 1)])
    let error = partial.difference(from: reference)
    near(error.first!.hz, 200, 1e-9, "error starts at shared coverage")
    near(error.last!.hz, 10000, 1e-7, "error ends at shared coverage")
    check(error.allSatisfy { abs($0.db - 2) < 1e-9 }, "positive error means above target")
    let separate = FrequencyResponse(name: "Separate", points: [
        .init(hz: 16000, db: 0), .init(hz: 20000, db: 0)])
    check(partial.difference(from: separate).isEmpty, "no overlap produces no error data")
    let corrected = partial.corrected(by: PEQProfile.flat.cascade(sampleRate: 48000), sampleRate: 48000)
    check(corrected.allSatisfy { $0.hz >= 100 && $0.hz <= 10000 },
          "corrected curve stays within measurement coverage")
}


section("Graphical PEQ draft preservation")
do {
    let global = "# keep original comment\nPreamp: -3.123456789 dB\nFilter 1: OFF LSC Fc 100.123456789 Hz Gain 2.123456789 dB Q 0.7123456789"
    let speaker = "Preamp: -2 dB\nFilter 1: ON PK Fc 2000 Hz Gain -4 dB Q 2"
    var draft = PEQEditDraft(global: global, speaker: speaker, swapsOutputs: false)
    check(!draft.hasChanges && draft.globalText == global && draft.speakerText == speaker,
          "opening and cancelling an editor preserves exact source text")
    let otherEar = draft.profile(.right)
    var left = draft.profile(.left)
    left.filters[0].frequency = 3000
    left.filters[0].gainDB = 5
    left.filters[0].q = 4
    draft.setProfile(left, for: .left)
    check(draft.profile(.right) == otherEar, "editing a mono fallback materializes and preserves the opposite ear")
    let roundTrip = APOParser.parse(draft.speakerText)
    check(roundTrip.profile(forChannel: 0) == left, "frequency gain and Q survive graphical serialization")
    check(roundTrip.profile(forChannel: 1) == otherEar, "opposite ear survives serialization")
    check(draft.globalText == global, "speaker edit preserves global source text")
    var g = draft.profile(.global)
    g.filters.append(PEQFilter(frequency: 7000, gainDB: -3, q: 1.5))
    draft.setProfile(g, for: .global)
    check(APOParser.parse(draft.globalText).firstProfile == g,
          "adding a band preserves disabled shelf type preamp and numeric precision")
    g.filters.removeLast()
    g.filters[0].enabled = true
    draft.setProfile(g, for: .global)
    check(APOParser.parse(draft.globalText).firstProfile == g, "delete and enable survive serialization")
    var swapped = PEQEditDraft(global: "", speaker: draft.speakerText, swapsOutputs: true)
    let untouched = swapped.profile(.right)
    var physicalLeft = swapped.profile(.left)
    physicalLeft.preampDB = -9
    swapped.setProfile(physicalLeft, for: .left)
    check(APOParser.parse(swapped.speakerText).profile(forChannel: 1) == physicalLeft,
          "physical left edits the routed right document channel when outputs are swapped")
    check(swapped.profile(.right) == untouched, "swapped edit preserves physical right")
    var unsupported = PEQEditDraft(global: "Include: extra.txt", speaker: "", swapsOutputs: false)
    unsupported.setProfile(g, for: .global)
    check(!unsupported.warnings.isEmpty && unsupported.globalText == "Include: extra.txt",
          "unsupported directives cannot be silently discarded by graphical edits")
    var empty = PEQEditDraft(global: "", speaker: "", swapsOutputs: false)
    empty.setProfile(PEQProfile(filters: [.init(frequency: 1000, gainDB: 2, q: 1)]), for: .global)
    check(APOParser.parse(empty.globalText).firstProfile.filters.count == 1,
          "a flat empty profile can gain its first editable band")
}

section("Gain-only PEQ editing, Reset and repeated Apply")
do {
    let source = "# original\nPreamp: -3 dB\nFilter 1: ON PK Fc 1234.567 Hz Gain -2 dB Q 1.234"
    var draft = PEQEditDraft(global: source, speaker: "", swapsOutputs: false)
    let original = draft.profile(.global)
    draft.setGain(5, at: 0, for: .global)
    near(draft.profile(.global).filters[0].frequency, 1234.567, 1e-12,
         "vertical dragging cannot change frequency")
    near(draft.profile(.global).filters[0].q, 1.234, 1e-12,
         "vertical dragging preserves bandwidth")
    check(draft.referenceProfile(.global) == original, "reference stays at the pre-edit curve")
    draft.reset()
    check(!draft.hasChanges && draft.globalText == source,
          "Reset restores exact source and clears the draft")
    draft.setGain(7, at: 0, for: .global)
    let appliedText = draft.globalText
    draft.acceptChanges()
    check(!draft.hasChanges && draft.originalGlobal == appliedText,
          "Apply accepts a new baseline without needing a new editor")
    draft.setGain(-4, at: 0, for: .global)
    check(draft.hasChanges, "editing can continue after Apply")
    near(draft.referenceProfile(.global).filters[0].gainDB, 7, 1e-12,
         "reference after Apply shows the applied gain")
    draft.reset()
    check(draft.globalText == appliedText, "Reset after Apply retains the applied edits")
    draft.setGain(100, at: 0, for: .global)
    near(draft.profile(.global).filters[0].gainDB, 24, 1e-12, "drag gain is bounded")
    draft.setGain(.nan, at: 0, for: .global)
    near(draft.profile(.global).filters[0].gainDB, 24, 1e-12, "non-finite drag gain is ignored")
}

section("Horizontal PEQ editing sets frequency through the log axis")
do {
    let source = "Preamp: 0 dB\nFilter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1.5\nFilter 2: ON PK Fc 4000 Hz Gain 3 dB Q 2"
    let nyquistHalf = 23_520.0                       // 48 kHz × 0.49, as the editor clamps
    var draft = PEQEditDraft(global: source, speaker: "", swapsOutputs: false)

    draft.setFrequency(1037.4183, at: 0, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[0].frequency, 1040, 1e-12,
         "a drag above 1 kHz lands on a 10 Hz step, not 1037.4183 Hz")
    near(draft.profile(.global).filters[0].gainDB, -2, 1e-12, "horizontal dragging cannot change gain")
    near(draft.profile(.global).filters[0].q, 1.5, 1e-12, "horizontal dragging preserves bandwidth")
    draft.setFrequency(63.49, at: 0, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[0].frequency, 63, 1e-12, "below 1 kHz the step is 1 Hz")
    draft.setFrequency(5, at: 0, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[0].frequency, 20, 1e-12,
         "a drag off the left edge clamps to 20 Hz, as the inspector field does")
    draft.setFrequency(40_000, at: 0, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[0].frequency, nyquistHalf, 1e-12,
         "a drag past the caller's Nyquist limit clamps to it")
    draft.setFrequency(.nan, at: 0, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[0].frequency, nyquistHalf, 1e-12,
         "a non-finite frequency is ignored")

    draft.setBand(at: 1, for: .global, gainDB: -6, frequency: 2500, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[1].gainDB, -6, 1e-12, "a two-axis drag sets gain")
    near(draft.profile(.global).filters[1].frequency, 2500, 1e-12, "and frequency in the same move")
    near(draft.profile(.global).filters[0].frequency, nyquistHalf, 1e-12, "without disturbing the other bands")

    // Band order is deliberately fixed: dragging one band past another changes
    // nothing acoustically, so renumbering the points would only make the one
    // under the cursor jump.
    draft.setFrequency(100, at: 1, for: .global, maxFrequency: nyquistHalf)
    near(draft.profile(.global).filters[1].frequency, 100, 1e-12,
         "a band can be dragged below its neighbour")
    near(draft.profile(.global).filters[0].frequency, nyquistHalf, 1e-12,
         "and the list keeps its order, so the numbering does not jump")
    check(APOParser.parse(draft.globalText).firstProfile == draft.profile(.global),
          "frequency edits survive serialization")
}

section("Band removal, muting and the selection that follows")
do {
    let source = "Preamp: -1 dB\nFilter 1: ON PK Fc 100 Hz Gain 1 dB Q 1\nFilter 2: ON PK Fc 1000 Hz Gain 2 dB Q 1\nFilter 3: ON PK Fc 8000 Hz Gain 3 dB Q 1"
    var draft = PEQEditDraft(global: source, speaker: "", swapsOutputs: false)

    check(draft.removeFilter(at: 1, for: .global), "a row deletes its own band")
    check(draft.profile(.global).filters.count == 2, "the list shrinks by one")
    near(draft.profile(.global).filters[1].frequency, 8000, 1e-12,
         "the band below slides up into the gap")
    check(!draft.removeFilter(at: 7, for: .global), "a stale index removes nothing")

    check(PEQEditDraft.selectionAfterRemoval(of: 1, count: 3) == 1,
          "the selection follows the band that took the deleted one's place")
    check(PEQEditDraft.selectionAfterRemoval(of: 2, count: 3) == 1,
          "deleting the last band selects the new last one")
    check(PEQEditDraft.selectionAfterRemoval(of: 0, count: 1) == nil,
          "deleting the only band is the one case that clears the selection")

    draft.setEnabled(false, at: 0, for: .global)
    check(draft.profile(.global).filters[0].enabled == false,
          "a band can be silenced instead of destroyed")
    check(APOParser.parse(draft.globalText).firstProfile.filters[0].enabled == false,
          "the mute survives serialization")

    draft.reset()
    check(draft.globalText == source && draft.profile(.global).filters.count == 3,
          "Reset restores deleted bands — deletion is a draft edit, not a final one")
}

section("Live audition ramps toward the draft instead of stepping to it")
do {
    let flat = PEQProfile(preampDB: 0, filters: [PEQFilter(frequency: 1000, gainDB: 0, q: 1)])
    var target = flat
    target.filters[0].gainDB = 12
    target.preampDB = -6

    var current = flat, ticks = 0, worstGainStep = 0.0
    while current != target && ticks < 500 {
        let next = PEQAudition.step(current, toward: target)
        worstGainStep = max(worstGainStep,
                            abs(next.filters[0].gainDB - current.filters[0].gainDB),
                            abs(next.preampDB - current.preampDB))
        current = next
        ticks += 1
    }
    check(current == target, "the audition arrives at the draft exactly", "after \(ticks) ticks")
    check(worstGainStep <= PEQAudition.maxGainStepDB + 1e-12,
          "no tick moves gain by more than the stated cap", "worst \(fmt(worstGainStep)) dB")
    check(ticks == 8, "a 12 dB flick lands in eight ticks — under half a second at 25 Hz",
          "got \(ticks)")

    var swept = flat
    swept.filters[0].frequency = 8000                 // three octaves
    current = flat; ticks = 0
    var worstOctaves = 0.0
    while current != swept && ticks < 500 {
        let next = PEQAudition.step(current, toward: swept)
        worstOctaves = max(worstOctaves,
                           abs(log2(next.filters[0].frequency / current.filters[0].frequency)))
        current = next
        ticks += 1
    }
    check(current == swept, "a frequency drag converges exactly too", "after \(ticks) ticks")
    check(worstOctaves <= PEQAudition.maxFrequencyStepOctaves + 1e-12,
          "no tick moves frequency by more than a quarter octave",
          "worst \(fmt(worstOctaves)) octaves")

    // Structural edits have nothing to interpolate between, and are also the
    // ones that do not produce a loud step.
    var added = flat
    added.filters.append(PEQFilter(frequency: 200, gainDB: 9, q: 1))
    check(PEQAudition.step(flat, toward: added) == added, "adding a band snaps")
    var muted = flat
    muted.filters[0].enabled = false
    check(PEQAudition.step(flat, toward: muted) == muted, "switching a band off snaps")
    var reshaped = flat
    reshaped.filters[0].kind = .lowShelf
    check(PEQAudition.step(flat, toward: reshaped) == reshaped, "changing the filter kind snaps")

    let from = PEQAudition.Stages(global: flat, left: flat, right: flat)
    let to = PEQAudition.Stages(global: target, left: flat, right: target)
    var stages = from, stageTicks = 0
    while stages != to && stageTicks < 500 { stages = stages.stepped(toward: to); stageTicks += 1 }
    check(stages == to, "all three stages converge together", "\(stageTicks) ticks")
    check(from.stepped(toward: from) == from, "an unchanged draft costs nothing")
}

section("One audition tick fits in the control-thread budget")
do {
    // The editor coalesces drag events onto a 25 Hz tick. Each tick costs one
    // SoundMixProcessor.apply, which allocates a render state and rebuilds every
    // biquad chain, the limiter and the delay buffers.
    let bands = (0..<12).map {
        PEQFilter(frequency: 40 * pow(2, Double($0) / 2), gainDB: Double($0) - 6, q: 1.2)
    }
    var config = ProcessorConfiguration(layout: .nativeBed, recipe: .reference)
    config.globalPEQ = PEQProfile(preampDB: -6, filters: bands)
    config.speakerPEQLeft = PEQProfile(preampDB: -1, filters: bands)
    config.speakerPEQRight = PEQProfile(preampDB: -1, filters: bands)

    func cost(_ base: ProcessorConfiguration, _ label: String) -> Double {
        let processor = SoundMixProcessor()
        processor.prepare(sampleRate: sr)
        var config = base
        let applies = 250                              // ten seconds of dragging
        let start = Date()
        for i in 0..<applies {
            config.globalPEQ.filters[0].gainDB = Double(i % 12) - 6
            processor.apply(config)
        }
        let ms = Date().timeIntervalSince(start) / Double(applies) * 1000
        print(String(format: "       %@: %.2f ms per rebuild, %.1f%% of a 40 ms tick", label, ms, ms / 40 * 100))
        return ms
    }

    check(cost(config, "matrix fold") < 4,
          "a matrix-fold tick costs a small fraction of the 40 ms budget")
    var binaural = config
    binaural.binaural = .virtualSpeakers
    check(cost(binaural, "binaural fold") < 8,
          "a binaural tick stays bounded too — the bank is cached, not regenerated")
}

section("Limiter channel isolation and live handoff")
do {
    let a = TruePeakLimiter(), b = TruePeakLimiter()
    var maxDifference = 0.0
    for n in 0..<10000 {
        var l = 1.2 * sin(Double(n) * 0.91), r = 0.7 * cos(Double(n) * 0.27)
        var swappedL = r, swappedR = l
        a.process(&l, &r); b.process(&swappedL, &swappedR)
        maxDifference = max(maxDifference, abs(l - swappedR), abs(r - swappedL))
    }
    near(maxDifference, 0, 1e-12, "limiter is invariant under channel exchange")
    let control = SoundMixProcessor(), edited = SoundMixProcessor()
    let cfg = ProcessorConfiguration()
    for p in [control, edited] { p.applyNow(cfg); p.prepare(sampleRate: 48000) }
    var input = [Float](repeating: 0.25, count: 128 * 16)
    var x = [Float](repeating: 0, count: 256), y = x
    control.process(input: &input, inputChannels: 16, frames: 128, output: &x)
    edited.process(input: &input, inputChannels: 16, frames: 128, output: &y)
    edited.apply(cfg)
    control.process(input: &input, inputChannels: 16, frames: 128, output: &x)
    edited.process(input: &input, inputChannels: 16, frames: 128, output: &y)
    check(x == y, "prepared handoff preserves filter and delay history")
}

section("Half-sample true peaks")
do {
    let limiter = TruePeakLimiter()
    var energy = 0.0
    // These sample values are below the ceiling, but the reconstructed sine is not.
    for n in 0..<30000 {
        var l = 1.2 * sin(.pi * 0.5 * Double(n) + .pi / 4), r = l
        limiter.process(&l, &r)
        if n >= 29000 { energy += l * l }
    }
    let reconstructedPeakDB = 20 * log10(sqrt(2 * energy / 1000))
    check(reconstructedPeakDB <= -0.99, "half-sample peaks respect -1 dBTP ceiling", "peak \(reconstructedPeakDB)")
}

section("Profile write failures")
do {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! Data("not a directory".utf8).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let lib = EQProfileLibrary(directory: path)
    do {
        _ = try lib.save(EQProfile(name: "Must fail"))
        check(false, "failed profile save throws")
    } catch { check(true, "failed profile save throws") }
    check(lib.profiles.isEmpty, "failed save does not claim persistence")
}

// MARK: - Binaural / HRTF fold

/// Deterministic pseudo-random source, so a failure is always reproducible.
struct TestNoise {
    var seed: UInt64 = 0x2545F4914F6CDD1D
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53) * 2 - 1
    }
}

/// Render interleaved stereo through a processor, in blocks of `blockFrames`.
func renderStereo(_ cfg: ProcessorConfiguration, sampleRate: Double = 48_000,
                  totalFrames: Int, blockFrames: Int = 512,
                  fill: (Int, Int) -> Float) -> [Double] {
    let channels = 16
    let proc = SoundMixProcessor()
    proc.applyNow(cfg)
    proc.prepare(sampleRate: sampleRate)
    proc.applyNow(cfg)
    var input = [Float](repeating: 0, count: blockFrames * channels)
    var output = [Float](repeating: 0, count: blockFrames * 2)
    var result = [Double](repeating: 0, count: totalFrames * 2)
    var done = 0
    while done < totalFrames {
        let n = min(blockFrames, totalFrames - done)
        for f in 0..<n {
            for c in 0..<channels { input[f * channels + c] = fill(done + f, c) }
        }
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                proc.process(input: inPtr.baseAddress!, inputChannels: channels,
                             frames: n, output: outPtr.baseAddress!)
            }
        }
        for f in 0..<n {
            result[(done + f) * 2] = Double(output[f * 2])
            result[(done + f) * 2 + 1] = Double(output[f * 2 + 1])
        }
        done += n
    }
    return result
}

func binauralConfig(_ profile: BinauralProfile,
                    layout: LayoutPreset = .nativeBed,
                    headroom: HeadroomMode = .none) -> ProcessorConfiguration {
    var cfg = ProcessorConfiguration(layout: layout, recipe: .reference,
                                     headroomMode: headroom, manualGainDB: 0)
    cfg.binaural = profile
    cfg.limiter = .init(ceilingDB: -1, lookaheadMS: 2, releaseMS: 80, enabled: false)
    return cfg
}

section("HRIR bank geometry")
do {
    let bank = HRIRBank.generate(profile: .virtualSpeakers, sampleRate: sr)
    check(bank.isMirrorSymmetric(), "the generated bank is an exact mirror pair by pair")
    check(bank.tapCount >= 64 && bank.tapCount % 8 == 0, "tap count is sane", "\(bank.tapCount)")

    // The head shadow has unity DC gain at every angle, which is what lets the
    // bass crossover sum back to flat.
    var worstDC = 0.0
    for ch in BedChannel.allCases where ch != .lfe {
        for ear in [HRIRBank.leftEar, HRIRBank.rightEar] {
            worstDC = max(worstDC, abs(bank.dcGain(ch, ear: ear) - 1))
        }
    }
    // Unity to within what the finite response can hold: the shadow filter's
    // tail is truncated at the end of the bank.
    near(worstDC, 0, 1e-5, "every impulse response has unity DC gain")

    // The fractional-delay kernel itself, which is what carries the ITD.
    let kernel = HRIRBank.fractionalDelayImpulse(delay: 12.5, tapCount: 64)
    near(kernel.reduce(0, +), 1.0, 1e-12, "the delay kernel has exactly unit DC gain")
    var weighted = 0.0
    for (n, h) in kernel.enumerated() { weighted += Double(n) * h }
    near(weighted, Double(HRIRBank.kernelHalfWidth) + 12.5, 1e-9,
         "the delay kernel sits exactly where it was asked to")

    near(bank.itdMicroseconds(.c), 0, 1e-6, "centre has no inter-aural delay")
    // Woodworth for an 8.75 cm head puts the onset difference at 261 us for 30
    // degrees and 656 us for 90. What is measured here is the energy centroid,
    // which runs tens of microseconds later on the shadowed ear because the
    // head shadow is a low-pass filter with its own group delay.
    near(bank.itdMicroseconds(.l), 261, 60, "front left ITD follows Woodworth")
    near(bank.itdMicroseconds(.ls), 656, 60, "side surround ITD is the maximum")
    check(bank.itdMicroseconds(.r) < 0, "the mirrored channel leads the other ear")
    check(abs(bank.itdMicroseconds(.ltm)) < abs(bank.itdMicroseconds(.ls)),
          "an elevated channel has less inter-aural delay than one in the ear plane")

    // Head shadow: the far ear is substantially quieter than the near ear.
    let near90 = bank.gainDB(.ls, ear: HRIRBank.leftEar)
    let far90 = bank.gainDB(.ls, ear: HRIRBank.rightEar)
    check(near90 - far90 > 6, "the far ear is shadowed by at least 6 dB",
          "near \(fmt(near90)) far \(fmt(far90))")
    // Rear sources lose high frequency: the front/back cue.
    check(bank.gainDB(.lrs, ear: HRIRBank.leftEar) < bank.gainDB(.ls, ear: HRIRBank.leftEar),
          "a rear channel is damped relative to the side channel")

    let cross = HRIRBank.generate(profile: .crossfeedOnly, sampleRate: sr)
    check(cross.isMirrorSymmetric(), "the crossfeed bank is mirror symmetric too")
    check(cross.gainDB(.l, ear: HRIRBank.rightEar) < cross.gainDB(.l, ear: HRIRBank.leftEar) - 4,
          "crossfeed reaches the opposite ear attenuated")
}

section("Binaural convolution against a naive reference")
do {
    let bank = HRIRBank.generate(profile: .virtualSpeakers, sampleRate: sr)
    let cap = 512
    let engine = BinauralFoldEngine(bank: bank, blockCapacity: cap)
    let n = 1400
    var noise = TestNoise()
    var x = [[Double]](repeating: [Double](repeating: 0, count: n), count: BedChannel.count)
    for c in 0..<BedChannel.count where c != BedChannel.lfe.rawValue {
        for t in 0..<n { x[c][t] = noise.next() }
    }

    var gotL = [Double](repeating: 0, count: n), gotR = [Double](repeating: 0, count: n)
    var bed = [Double](repeating: 0, count: BedChannel.count * cap)
    var oL = [Double](repeating: 0, count: cap), oR = [Double](repeating: 0, count: cap)
    // Uneven blocks, including some shorter than the filter, to exercise the
    // history shift in both the overlapping and non-overlapping case.
    let sizes = [1, 7, 512, 300, 37, 512, 120, 11]
    var t = 0, si = 0
    while t < n {
        let m = min(sizes[si % sizes.count], n - t); si += 1
        for c in 0..<BedChannel.count { for f in 0..<m { bed[c * cap + f] = x[c][t + f] } }
        bed.withUnsafeBufferPointer { b in
            oL.withUnsafeMutableBufferPointer { l in
                oR.withUnsafeMutableBufferPointer { r in
                    engine.process(bed: b.baseAddress!, bedStride: cap, frames: m,
                                   outL: l.baseAddress!, outR: r.baseAddress!)
                }
            }
        }
        for f in 0..<m { gotL[t + f] = oL[f]; gotR[t + f] = oR[f] }
        t += m
    }

    // The reference is the full four-convolutions-per-pair form, so this is
    // what proves the sum/difference shortcut.
    var hl = [[Double]](), hr = [[Double]]()
    for ch in BedChannel.allCases {
        hl.append(Array(bank.taps(ch, ear: HRIRBank.leftEar)))
        hr.append(Array(bank.taps(ch, ear: HRIRBank.rightEar)))
    }
    var worst = 0.0
    for t in 0..<n {
        var l = 0.0, r = 0.0
        for c in 0..<BedChannel.count where c != BedChannel.lfe.rawValue {
            let xs = x[c]
            for k in 0..<bank.tapCount where k <= t {
                l += hl[c][k] * xs[t - k]
                r += hr[c][k] * xs[t - k]
            }
        }
        worst = max(worst, abs(l - gotL[t]), abs(r - gotR[t]))
    }
    near(worst, 0, 1e-9, "block convolution equals direct convolution, any block size")
}

section("Binaural null test against the amplitude matrix")
do {
    // Crossfeed with the opposite-ear copy driven to silence is a pure delay:
    // every channel reaches its own side at unity, the centre reaches both.
    // That is exactly a unity amplitude matrix, 16 samples late.
    let unity = MatrixRecipe(name: "Unity", centerGainDB: 0, lfeMode: .off)
    var silentCrossfeed = BinauralProfile.crossfeedOnly
    silentCrossfeed.crossfeedLevelDB = -400
    silentCrossfeed.lfe = LFESettings(mode: .off)

    let frames = 900
    var noise = TestNoise()
    var table = [Float](repeating: 0, count: frames * 16)
    for i in 0..<(frames * 16) { table[i] = Float(noise.next()) }
    let fill: (Int, Int) -> Float = { f, c in table[f * 16 + c] }

    var matrixCfg = ProcessorConfiguration(layout: .nativeBed, recipe: unity,
                                           headroomMode: .none, manualGainDB: 0)
    matrixCfg.limiter = .init(ceilingDB: -1, lookaheadMS: 2, releaseMS: 80, enabled: false)
    let viaMatrix = renderStereo(matrixCfg, totalFrames: frames, fill: fill)
    let viaBinaural = renderStereo(binauralConfig(silentCrossfeed), totalFrames: frames, fill: fill)

    let delay = HRIRBank.kernelHalfWidth
    var worst = 0.0
    for f in 0..<(frames - delay) {
        worst = max(worst, abs(viaBinaural[(f + delay) * 2] - viaMatrix[f * 2]),
                    abs(viaBinaural[(f + delay) * 2 + 1] - viaMatrix[f * 2 + 1]))
    }
    // Both paths quantise to 32-bit float on the way out, which sets the floor.
    near(worst, 0, 2e-7, "a delta filter bank reproduces the matrix path exactly")
}

section("Binaural headroom and the peak-safe guarantee")
do {
    var profile = BinauralProfile.virtualSpeakers
    profile.bassCrossoverHz = 0            // exact bound: no crossover in the way
    profile.lfe = LFESettings(mode: .off)
    let bank = HRIRBank.generate(profile: profile, sampleRate: sr)
    let active = LayoutPreset.nativeBed.activeChannels

    let safe = binauralConfig(profile, headroom: .peakSafe)
    let power = binauralConfig(profile, headroom: .powerPreserving)
    near(safe.automaticTrimDB, -SoundMixMatrix.dB(bank.worstCasePeakGain(for: active)), 1e-9,
         "peak-safe trims by the summed absolute taps")
    near(power.automaticTrimDB, -SoundMixMatrix.dB(bank.uncorrelatedGain(for: active)), 1e-9,
         "power-preserving trims by the summed tap energy")
    check(safe.automaticTrimDB < power.automaticTrimDB,
          "the peak bound costs more level than the power figure")

    // The trim is quoted at the reference rate, so it does not move when the
    // device changes rate.
    let at96 = HRIRBank.generate(profile: profile, sampleRate: 96_000)
    check(at96.tapCount > bank.tapCount, "the bank lengthens with the sample rate")
    near(safe.automaticTrimDB, -SoundMixMatrix.dB(bank.worstCasePeakGain(for: active)), 1e-9,
         "the quoted trim is rate independent")

    // Build the one signal that actually reaches the L1 bound: each channel
    // driven with the sign of its own left-ear response, reversed in time.
    let taps = bank.tapCount
    let hit = taps + 8
    var signs = [[Double]]()
    for ch in BedChannel.allCases { signs.append(Array(bank.taps(ch, ear: HRIRBank.leftEar))) }
    let worstCase: (Int, Int) -> Float = { f, c in
        guard c != BedChannel.lfe.rawValue else { return 0 }
        let k = hit - f
        guard k >= 0, k < taps else { return 0 }
        return signs[c][k] >= 0 ? 1 : -1
    }
    let rendered = renderStereo(safe, totalFrames: hit + 16, fill: worstCase)
    var peak = 0.0
    for f in 0..<(hit + 16) { peak = max(peak, abs(rendered[f * 2]), abs(rendered[f * 2 + 1])) }
    near(peak, 1.0, 1e-6, "the worst case signal reaches full scale and no further")
    check(peak <= 1.0 + 1e-9, "peak-safe cannot clip, even when the signal is built to",
          "peak \(fmt(peak))")
}

section("Bass crossover")
do {
    /// Steady-state RMS of both ears for a sine on one bed channel.
    func toneRMS(_ cfg: ProcessorConfiguration, channel: BedChannel, hz: Double) -> (l: Double, r: Double) {
        let total = 16384 + 8192
        let out = renderStereo(cfg, totalFrames: total, fill: { f, c in
            c == channel.rawValue ? Float(sin(2 * .pi * hz * Double(f) / sr)) : 0
        })
        var l = 0.0, r = 0.0
        for f in 16384..<total { l += out[f * 2] * out[f * 2]; r += out[f * 2 + 1] * out[f * 2 + 1] }
        let n = Double(total - 16384)
        return ((l / n).squareRoot(), (r / n).squareRoot())
    }

    var split = BinauralProfile.virtualSpeakers
    split.lfe = LFESettings(mode: .off)
    var flat = split
    flat.bassCrossoverHz = 0

    // The crossover must put back what it takes out: a centre source has no
    // inter-aural delay, so the two legs realign exactly.
    var worst = 0.0
    for hz in [40.0, 80, 150, 300, 600, 2000] {
        let a = toneRMS(binauralConfig(split), channel: .c, hz: hz)
        let b = toneRMS(binauralConfig(flat), channel: .c, hz: hz)
        worst = max(worst, abs(20 * log10(a.l / b.l)))
    }
    check(worst < 0.35, "splitting the bass out and back leaves the centre flat",
          "worst deviation \(fmt(worst)) dB")

    // Bass is folded to both ears equally; the top stays where it was panned.
    let low = toneRMS(binauralConfig(split), channel: .ls, hz: 50)
    let high = toneRMS(binauralConfig(split), channel: .ls, hz: 4000)
    check(abs(20 * log10(low.l / low.r)) < 0.5, "below the crossover a hard-left source is centred",
          "\(fmt(20 * log10(low.l / low.r))) dB")
    check(20 * log10(high.l / high.r) > 6, "above it the same source stays on the left",
          "\(fmt(20 * log10(high.l / high.r))) dB")
}

section("Binaural latency and block independence")
do {
    var profile = BinauralProfile.virtualSpeakers
    profile.bassCrossoverHz = 0
    profile.lfe = LFESettings(mode: .off)
    let cfg = binauralConfig(profile)

    let proc = SoundMixProcessor()
    proc.applyNow(cfg)
    proc.prepare(sampleRate: sr)
    proc.applyNow(cfg)
    let reportedSamples = (proc.latencyMS / 1000 * sr).rounded()

    let out = renderStereo(cfg, totalFrames: 256, fill: { f, c in
        f == 0 && c == BedChannel.c.rawValue ? 1 : 0
    })
    // The reported latency is the bulk delay of the bank, so the honest
    // comparison is against the centroid of the rendered impulse, not its peak.
    var weighted = 0.0, total = 0.0, peakIndex = 0, peak = 0.0
    for f in 0..<256 {
        let a = abs(out[f * 2])
        weighted += Double(f) * a
        total += a
        if a > peak { peak = a; peakIndex = f }
    }
    near(weighted / total, reportedSamples, 0.5,
         "the impulse arrives exactly when the reported latency says")
    check(abs(Double(peakIndex) - reportedSamples) <= 2,
          "and its peak lands within a couple of samples of that", "peak at \(peakIndex)")

    var noise = TestNoise()
    var table = [Float](repeating: 0, count: 700 * 16)
    for i in 0..<(700 * 16) { table[i] = Float(noise.next()) }
    let fill: (Int, Int) -> Float = { f, c in table[f * 16 + c] }
    let big = renderStereo(binauralConfig(.virtualSpeakers), totalFrames: 700, blockFrames: 512, fill: fill)
    let small = renderStereo(binauralConfig(.virtualSpeakers), totalFrames: 700, blockFrames: 37, fill: fill)
    let single = renderStereo(binauralConfig(.virtualSpeakers), totalFrames: 700, blockFrames: 1, fill: fill)
    var worst = 0.0
    for i in 0..<(700 * 2) {
        worst = max(worst, abs(big[i] - small[i]), abs(big[i] - single[i]))
    }
    near(worst, 0, 1e-12, "the output does not depend on the buffer size it was rendered in")
}

section("Binaural render cost")
do {
    let cfg = binauralConfig(.virtualSpeakers, headroom: .powerPreserving)
    let seconds = 10.0
    let total = Int(sr * seconds)
    var noise = TestNoise()
    var table = [Float](repeating: 0, count: 512 * 16)
    for i in 0..<(512 * 16) { table[i] = Float(noise.next()) }
    let start = Date()
    _ = renderStereo(cfg, totalFrames: total, blockFrames: 512,
                     fill: { f, c in table[(f % 512) * 16 + c] })
    let elapsed = Date().timeIntervalSince(start)
    let realtimeFactor = seconds / max(elapsed, 1e-9)
    check(realtimeFactor > 20, "the binaural fold renders well faster than real time",
          String(format: "%.0fx real time", realtimeFactor))
    print("       \(String(format: "%.0fx", realtimeFactor)) real time at 48 kHz, 16 channels in")

    // The bank lengthens with the rate and the block count rises with it, so
    // the cost grows faster than linearly. 192 kHz is the worst case a device
    // can ask for.
    for rate in [96_000.0, 192_000.0] {
        let frames = Int(rate * 4)
        let begin = Date()
        _ = renderStereo(cfg, sampleRate: rate, totalFrames: frames, blockFrames: 512,
                         fill: { f, c in table[(f % 512) * 16 + c] })
        let factor = 4.0 / max(Date().timeIntervalSince(begin), 1e-9)
        check(factor > 2, "still faster than real time at \(Int(rate / 1000)) kHz",
              String(format: "%.1fx real time", factor))
        print("       \(String(format: "%.1fx", factor)) real time at \(Int(rate / 1000)) kHz")
    }
}

section("Bundled target references")
do {
    let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Resources/Targets")
    var loaded: [BuiltInTarget: FrequencyResponse] = [:]
    check(!BuiltInTarget.all.isEmpty,
          "the bundled target manifest lists at least one target")
    check(BuiltInTarget.all.count == Set(BuiltInTarget.all.map(\.id)).count,
          "the bundled target manifest has unique ids")
    for target in BuiltInTarget.all {
        do {
            let curve = try target.load(from: directory)
            loaded[target] = curve
            check(curve.name == target.name,
                  "\(target.name) parses under its display name")
            check(curve.points.count > 400,
                  "\(target.name) has enough points to plot")
            check(curve.range.low <= 20 && curve.range.high >= 19000,
                  "\(target.name) covers the audible comparison range")
            check(curve.points.allSatisfy { $0.hz.isFinite && $0.db.isFinite && $0.hz > 0 },
                  "\(target.name) has finite positive frequency samples")
            let normalized = curve.normalized()
            check(normalized.difference(from: normalized).allSatisfy { abs($0.db) < 1e-9 },
                  "\(target.name) matches itself in error view")
        } catch {
            check(false, "\(target.name) loads", error.localizedDescription)
        }
    }
    let neutral = BuiltInTarget.all.first { $0.id == "ief-neutral" }
    let bass = BuiltInTarget.all.first { $0.id == "ief-neutral-bass" }
    check(neutral != nil && bass != nil,
          "the manifest keeps both IEF Neutral variants")
    if let neutral, let bass, let neutralCurve = loaded[neutral], let bassCurve = loaded[bass] {
        check(bassCurve.magnitudeDB(at: 20) > neutralCurve.magnitudeDB(at: 20) + 5,
              "IEF Neutral and bass variants remain distinct")
    }
    do {
        if let any = BuiltInTarget.all.first {
            _ = try any.load(from: directory.appendingPathComponent("missing"))
            check(false, "missing target returns an error instead of a fabricated curve")
        }
    } catch {
        check(true, "missing target returns an error instead of a fabricated curve")
    }
}

section("Non-finite input containment")
do {
    // A wedged capture device may deliver NaN or infinities. Every stage must
    // either mute them or recover, never latch them into state.
    var l = Double.nan, r = Double.infinity
    TruePeakLimiter().process(&l, &r)
    check(l.isFinite && r.isFinite, "limiter mutes non-finite frames instead of passing them")

    var meter = LevelMeter()
    meter.configure(sampleRate: sr)
    meter.accumulate(.nan)
    meter.accumulate(0.5)
    check(meter.rmsDB.isFinite, "meter RMS recovers after a NaN sample")

    let proc = SoundMixProcessor()
    var cfg = ProcessorConfiguration()
    cfg.globalPEQ = PEQProfile(preampDB: 0, filters: [
        PEQFilter(frequency: 1000, gainDB: 6, q: 1)
    ])
    proc.applyNow(cfg)
    proc.prepare(sampleRate: sr)
    proc.applyNow(cfg)
    var input = [Float](repeating: 0, count: 64 * 16)
    for i in 0..<64 { input[i * 16] = .nan; input[i * 16 + 1] = .infinity }
    var output = [Float](repeating: 0, count: 64 * 2)
    proc.noteUnderrun()
    proc.noteUnderrun()
    proc.process(input: &input, inputChannels: 16, frames: 64, output: &output)
    check(output.allSatisfy { $0.isFinite }, "processor mutes non-finite input at ingestion")
    let snap = proc.snapshot()
    // Silence meters read as the -.infinity floor by design; what must never
    // happen is NaN latching into the one-pole state.
    check(!snap.outputRMSDB.0.isNaN && !snap.outputRMSDB.1.isNaN,
          "snapshot meters never latch NaN")
    check(snap.underruns == 2, "underrun counts survive a snapshot round trip")
}

section("Locked control APIs")
do {
    // applyNow / prepare / reset swap whole states under the lock; repeated
    // calls and interleaved reads must stay coherent.
    let proc = SoundMixProcessor()
    var cfg = ProcessorConfiguration()
    cfg.globalPEQ = PEQProfile(preampDB: 0, filters: [
        PEQFilter(frequency: 60, gainDB: 4, q: 0.9)
    ])
    proc.applyNow(cfg)
    proc.prepare(sampleRate: 96_000)
    check(proc.configuration == cfg, "applyNow followed by prepare keeps the configuration")
    proc.reset()
    check(proc.configuration == cfg, "reset keeps the configuration")

    // A live-style queued apply still lands on the next block.
    var edited = cfg
    edited.globalPEQ.filters[0].gainDB = -4
    proc.apply(edited)
    var input = [Float](repeating: 0.1, count: 32 * 16)
    var output = [Float](repeating: 0, count: 32 * 2)
    proc.process(input: &input, inputChannels: 16, frames: 32, output: &output)
    check(proc.configuration == edited, "queued apply is adopted by the next processed block")
}

section("Averaged response")
do {
    let a = FrequencyResponse.parse(
        "20 1\n100 2\n1000 3\n2000 2\n5000 1\n10000 0\n20000 -1\n30000 -2", name: "A")!
    let b = FrequencyResponse.parse(
        "20 3\n100 2\n1000 1\n2000 2\n5000 3\n10000 2\n20000 1\n30000 2", name: "B")!
    let avg = FrequencyResponse.average([a, b], name: "Avg")!
    near(avg.magnitudeDB(at: 20), 2.0, 0.01, "average is the pointwise dB mean at the edges")
    near(avg.magnitudeDB(at: 1000), 2.0, 0.01, "interior points average too")
    check(FrequencyResponse.average([], name: "none") == nil, "averaging nothing is nil")
    check(FrequencyResponse.average([a], name: "one")! == a, "a single curve passes through")
}

section("AutoTune flattens toward the target")
do {
    // A measurement with a +6 dB bump at 1 kHz and a −5 dB dip at 200 Hz.
    var lines: [String] = []
    for i in 0..<48 {
        let hz = 20.0 * pow(1000.0, Double(i) / 47)
        var db = 0.0
        if hz < 500 { db -= 5 * (1 - abs(log2(hz / 200)) / 2) }   // dip centred on 200 Hz
        if hz >= 500 { db += 6 * exp(-pow(log2(hz / 1000), 2) * 8) } // bump centred on 1 kHz
        lines.append("\(Int(hz.rounded())) \(String(format: "%.3f", db))")
    }
    let measured = FrequencyResponse.parse(lines.joined(separator: "\n"), name: "M")!
    var flatLines: [String] = []
    for i in 0..<48 {
        let hz = 20.0 * pow(1000.0, Double(i) / 47)
        flatLines.append("\(Int(hz.rounded())) 0")
    }
    let flat = FrequencyResponse.parse(flatLines.joined(separator: "\n"), name: "T")!

    let bands = AutoTune.bands(matching: measured, to: flat, sampleRate: 48_000)
    check(!bands.isEmpty, "a bumpy measurement gets bands")
    check(bands.count <= 30, "no more than 30 bands", "\(bands.count)")
    check(bands.allSatisfy { $0.kind == .peaking && $0.enabled }, "only peaking filters")

    func worstDeviation(_ curve: FrequencyResponse, from target: FrequencyResponse) -> Double {
        // Compared only where both curves are measured: outside the shared
        // range the endpoint hold pits one curve's edge against the other.
        curve.normalized().difference(from: target.normalized(),
                                      low: 30, high: 1_500).map { abs($0.db) }.max() ?? 0
    }
    let before = worstDeviation(measured, from: flat)
    let corrected = measured.corrected(
        by: PEQProfile(preampDB: 0, filters: bands).cascade(sampleRate: 48_000),
        sampleRate: 48_000)
    let after = worstDeviation(FrequencyResponse(name: "", points: corrected), from: flat)
    check(after < before, "the correction reduces worst deviation",
          "before \(String(format: "%.2f", before)) after \(String(format: "%.2f", after))")
    check(after < before * 0.5, "a simple bump is mostly flattened",
          "after \(String(format: "%.2f", after)) dB")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("All DSP checks passed.")
