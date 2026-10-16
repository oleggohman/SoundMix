import SwiftUI
import Combine
import AppKit

/// One line of the event log, with an identity that survives the 500-line
/// sliding window: identifying rows by offset re-id'd every row on append.
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
final class AppModel: ObservableObject {

    // Devices
    @Published var devices: [AudioDevice] = []
    @Published var inputUID: String = ""
    @Published var outputUID: String = ""
    @Published var showIncompatibleDevices = false

    // Downmix
    @Published var layoutName: String = LayoutPreset.nativeBed.name
    @Published var recipeName: String = MatrixRecipe.reference.name
    @Published var customRecipe: MatrixRecipe = .reference
    @Published var headroomMode: HeadroomMode = .powerPreserving
    /// Fold through a head-related filter bank instead of the amplitude matrix.
    @Published var foldIsBinaural = false
    @Published var binauralName: String = BinauralProfile.virtualSpeakers.name
    @Published var headRadiusText: String = "8.75"
    @Published var bassCrossoverText: String = "150"
    @Published var rearDampingText: String = "-3.5"
    @Published var elevationCueText: String = "-8"
    @Published var manualGainText: String = "0"
    @Published var swapOutputs = false

    // LFE (edited on the working recipe)
    @Published var lfeMode: LFEMode = .off
    @Published var lfeCutoffText: String = "120"
    @Published var lfeOrder: Int = 4
    @Published var lfeGainText: String = "0"

    // Limiter
    @Published var limiterEnabled = true
    @Published var limiterCeilingText: String = "-1.0"
    @Published var limiterReleaseText: String = "80"

    // PEQ
    @Published var globalPEQText: String = ""
    @Published var speakerPEQText: String = ""
    @Published var peqWarnings: [String] = []

    // EQ profile library
    @Published var profiles: [EQProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var profileNameDraft: String = ""
    @Published var profileNotesDraft: String = ""
    /// A/B: force both EQ stages flat without losing the text.
    @Published var eqBypassed = false
    @Published var profileDirty = false
    @Published var speakerSectionCollapsed = false
    /// The earphone curves paired with the current EQ, one per ear.
    @Published var measurementLeft: FrequencyResponse?
    @Published var measurementRight: FrequencyResponse?
    /// The reference curve the correction aims at.
    @Published var target: FrequencyResponse?
    @Published var measurementError: String?
    /// Curves the viewer has switched off in the Response plot.
    @Published var hiddenTraces: Set<String> = []

    // Engine options
    @Published var framesPerBuffer: Int = 128
    @Published var safetyBufferText: String = "20"

    // Runtime
    @Published var state: EngineState = .stopped
    @Published var snapshot = RenderSnapshot()
    @Published var log: [LogLine] = []
    @Published var errorMessage: String?
    @Published var micStatus: MicrophoneAccess.Status = MicrophoneAccess.status

    let directory = AudioDeviceDirectory()
    let engine = SoundMixEngine()
    /// The profile library is injectable so tests can point it at a scratch
    /// directory. The default is the user's real Application Support folder —
    /// a test that forgets to override it would otherwise write real profiles.
    let library: EQProfileLibrary
    private var meterTimer: Timer?

    /// True while the plot editor is auditioning an uncommitted draft, so the
    /// headroom readouts describe what is being heard rather than what is saved.
    @Published private(set) var auditioningPEQ = false
    private var audition: PEQAuditionState?
    private var auditionTimer: Timer?
    /// One rebuild per tick at most, however fast the mouse moves.
    static let auditionTickSeconds = 1.0 / 25

    init(library: EQProfileLibrary = EQProfileLibrary()) {
        self.library = library
        devices = directory.devices
        inputUID = devices.first(where: { $0.isDefaultInput && $0.hasInput })?.uid
            ?? devices.first(where: \.hasInput)?.uid ?? ""
        outputUID = devices.first(where: { $0.isDefaultOutput })?.uid
            ?? devices.first(where: \.hasOutput)?.uid ?? ""

        directory.onChange = { [weak self] list in
            guard let self else { return }
            self.devices = list
            self.append("Audio device list changed — \(list.count) devices present.")
        }
        engine.onStateChange = { [weak self] s in
            guard let self else { return }
            self.state = s
            if case .failed(let message) = s {
                self.errorMessage = message
                self.append("Stopped: \(message)")
            }
        }
        engine.onLog = { [weak self] line in self?.append(line) }

        load()
        profiles = library.profiles
        if let id = selectedProfileID, let p = profiles.first(where: { $0.id == id }) {
            profileNameDraft = p.name
            profileNotesDraft = p.notes
        }

        startMeterTimer()
        append("SoundMix ready.")
    }

    // MARK: - Derived

    var inputDevice: AudioDevice? { devices.first { $0.uid == inputUID } }
    var outputDevice: AudioDevice? { devices.first { $0.uid == outputUID } }

    var layout: LayoutPreset {
        LayoutPreset.all.first { $0.name == layoutName } ?? .nativeBed
    }

    var availableRecipes: [MatrixRecipe] { MatrixRecipe.builtIns }

    /// The recipe with the live LFE edits folded in.
    var workingRecipe: MatrixRecipe {
        var r = availableRecipes.first { $0.name == recipeName } ?? .reference
        r.lfeMode = lfeMode
        r.lfeCutoffHz = Double(lfeCutoffText) ?? r.lfeCutoffHz
        r.lfeFilterOrder = lfeOrder
        r.lfeGainDB = Double(lfeGainText) ?? r.lfeGainDB
        return r
    }

    var availableBinaurals: [BinauralProfile] { BinauralProfile.builtIns }

    /// The binaural profile with the live editor values folded in, the same way
    /// `workingRecipe` folds in the LFE edits.
    var workingBinaural: BinauralProfile {
        var p = availableBinaurals.first { $0.name == binauralName } ?? .virtualSpeakers
        p.headRadiusCM = Double(headRadiusText) ?? p.headRadiusCM
        p.bassCrossoverHz = Double(bassCrossoverText) ?? p.bassCrossoverHz
        p.rearDampingDB = Double(rearDampingText) ?? p.rearDampingDB
        p.elevationCueDB = Double(elevationCueText) ?? p.elevationCueDB
        p.lfe = LFESettings(mode: lfeMode,
                            gainDB: Double(lfeGainText) ?? 0,
                            cutoffHz: Double(lfeCutoffText) ?? 120,
                            filterOrder: lfeOrder)
        return p
    }

    /// The bank the interface describes: built for the running device rate so
    /// The sample rate plots and profile analysis should assume: the engine's
    /// live rate when rendering, 48 kHz otherwise. One definition, because it
    /// appeared nine times across the interface.
    var plotSampleRate: Double { state.isRunning ? engine.currentSampleRate : 48_000 }

    /// the inter-aural delays shown are the ones actually being rendered.
    var displayedBank: HRIRBank? {
        guard foldIsBinaural else { return nil }
        return HRIRBank.cached(profile: workingBinaural, sampleRate: plotSampleRate)
    }

    var globalProfile: PEQProfile {
        guard !eqBypassed, !globalPEQText.isEmpty else { return .flat }
        return APOParser.parse(globalPEQText).firstProfile
    }
    var speakerProfiles: (left: PEQProfile, right: PEQProfile) {
        guard !eqBypassed, !speakerPEQText.isEmpty else { return (.flat, .flat) }
        return APOParser.parse(speakerPEQText).speakerProfiles(swappingOutputs: swapOutputs)
    }

    var configuration: ProcessorConfiguration {
        let speakers = speakerProfiles
        return ProcessorConfiguration(
            layout: layout,
            recipe: workingRecipe,
            headroomMode: headroomMode,
            manualGainDB: Double(manualGainText) ?? 0,
            swapOutputs: swapOutputs,
            globalPEQ: globalProfile,
            speakerPEQLeft: speakers.left,
            speakerPEQRight: speakers.right,
            limiter: TruePeakLimiter.Settings(
                ceilingDB: Double(limiterCeilingText) ?? -1,
                lookaheadMS: 2,
                releaseMS: Double(limiterReleaseText) ?? 80,
                enabled: limiterEnabled),
            binaural: foldIsBinaural ? workingBinaural : nil)
    }

    var limiterStatus: String {
        guard state.isRunning else { return "Stopped" }
        guard engine.currentConfiguration.limiter.enabled else { return "Off" }
        return snapshot.gainReductionDB > 0.05
            ? String(format: "−%.1f dB", snapshot.gainReductionDB) : "Ready · 0 dB"
    }

    var gainBreakdown: String {
        let cfg = configuration
        let eq = auditionedEQStages
        return String(format: "Fold trim %+.1f dB · manual %+.1f dB · global EQ preamp %+.1f dB · speaker preamps L %+.1f / R %+.1f dB.%@ EQ filters add their own frequency-dependent boosts and cuts.",
                      cfg.automaticTrimDB, cfg.manualGainDB, eq.global.preampDB,
                      eq.left.preampDB, eq.right.preampDB,
                      auditioningPEQ ? " Auditioning an unsaved draft from the plot editor." : "")
    }

    func adjustManualGain(by delta: Double) {
        let value = Double(manualGainText) ?? 0
        guard value.isFinite else { return }
        manualGainText = String(format: "%.1f", min(24, max(-60, value + delta)))
        applyLive()
    }

    var engineOptions: SoundMixEngine.Options {
        .init(framesPerBuffer: framesPerBuffer,
              safetyBufferMS: Double(safetyBufferText) ?? 20)
    }

    var compatibleInputs: [AudioDevice] {
        let needed = layout.requiredInputChannels
        return devices.filter { $0.hasInput && (showIncompatibleDevices || $0.inputChannels >= needed) }
    }
    var compatibleOutputs: [AudioDevice] {
        devices.filter { $0.hasOutput && (showIncompatibleDevices || $0.outputChannels >= 2) }
    }

    var startBlockedReason: String? {
        guard let input = inputDevice else { return "Select an input device." }
        guard let output = outputDevice else { return "Select an output device." }
        let needed = layout.requiredInputChannels
        if input.inputChannels < needed {
            return "“\(input.name)” has \(input.inputChannels) input channels; \(layout.name) needs \(needed)."
        }
        if output.outputChannels < 2 {
            return "“\(output.name)” cannot play stereo."
        }
        return nil
    }

    // MARK: - Transport

    func start() {
        errorMessage = nil
        guard inputDevice != nil, outputDevice != nil else { return }

        // Every Core Audio input counts as a microphone to macOS. Ask first;
        // opening the capture unit without authorisation simply blocks.
        if MicrophoneAccess.status == .notDetermined {
            append("Requesting microphone access — macOS requires it for any audio input device.")
        }
        MicrophoneAccess.request { [weak self] status in
            guard let self else { return }
            self.micStatus = status
            guard status.canCapture else {
                self.errorMessage = MicrophoneAccess.explanation(for: status)
                self.append("Cannot start: microphone access is \(status).")
                return
            }
            self.launch()
        }
    }

    private var runningEngineSettings: EngineSettings?

    private func launch() {
        guard let input = inputDevice, let output = outputDevice else { return }
        do {
            try engine.start(input: input, output: output,
                             configuration: configuration, options: engineOptions)
            runningEngineSettings = currentEngineSettings
        } catch {
            runningEngineSettings = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stop() {
        engine.stop()
        runningEngineSettings = nil
    }

    /// The settings that are baked into the open audio units. Changing any of
    /// them cannot be done on the fly — the units have to be reopened.
    struct EngineSettings: Equatable {
        var inputUID: String
        var outputUID: String
        var framesPerBuffer: Int
        var safetyBufferMS: Double
    }

    var currentEngineSettings: EngineSettings {
        EngineSettings(inputUID: inputUID, outputUID: outputUID,
                       framesPerBuffer: framesPerBuffer,
                       safetyBufferMS: Double(safetyBufferText) ?? 20)
    }

    /// True when the open stream no longer matches the chosen devices or buffering.
    var needsRestartToApply: Bool {
        guard state.isRunning, let running = runningEngineSettings else { return false }
        return running != currentEngineSettings
    }

    /// Plain-language reason a restart is required, for the transport bar.
    var restartReason: String? {
        guard let running = runningEngineSettings, needsRestartToApply else { return nil }
        let now = currentEngineSettings
        var parts: [String] = []
        if running.inputUID != now.inputUID { parts.append("input device") }
        if running.outputUID != now.outputUID { parts.append("output device") }
        if running.framesPerBuffer != now.framesPerBuffer { parts.append("buffer size") }
        if running.safetyBufferMS != now.safetyBufferMS { parts.append("safety buffer") }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return "Changing the \(list) reopens the audio stream."
    }

    /// Hot-applies what can be changed while streaming, and reopens the stream
    /// for the things that cannot. Before, this only pushed DSP parameters, so
    /// a device or buffer change silently did nothing until you stopped and
    /// started by hand.
    func applyLive() {
        // Whatever the plot editor was auditioning, this push carries the
        // committed EQ; a lagging audition tail would overwrite it a tick later.
        discardPEQAudition()
        guard state.isRunning else { return }
        if needsRestartToApply {
            append("Reopening the audio stream to apply the new device or buffer settings…")
            engine.stop()
            launch()
            return
        }
        engine.apply(configuration)
        append(String(format: "Applied · trim %+.1f dB · worst case %+.1f dB",
                      configuration.totalTrimDB,
                      configuration.foldPeakGainDB))
    }

    /// The Output EQ editors' Apply: what you hear and what is saved are one
    /// step — push the text to the engine, then persist it to the profile
    /// library (creating a profile when none is selected).
    /// The transport bar and ⌘S route here too, so any control named Apply
    /// both sounds and saves.
    func applyAndSavePEQ() {
        reloadPEQWarnings()
        applyLive()
        saveSelectedProfile()
    }

    /// Commit a graphical draft without applying unrelated device or matrix edits.
    func applyPEQDraft(_ draft: PEQEditDraft) -> Bool {
        guard draft.warnings.isEmpty,
              draft.originalGlobal == globalPEQText, draft.originalSpeaker == speakerPEQText,
              draft.swapsOutputs == swapOutputs else { return false }
        globalPEQText = draft.globalText
        speakerPEQText = draft.speakerText
        reloadPEQWarnings()
        markProfileDirty()
        if state.isRunning {
            var config = engine.currentConfiguration
            config.globalPEQ = globalProfile
            let speakers = eqBypassed || speakerPEQText.isEmpty
                ? (PEQProfile.flat, PEQProfile.flat)
                : APOParser.parse(speakerPEQText).speakerProfiles(swappingOutputs: swapOutputs)
            config.speakerPEQLeft = speakers.0
            config.speakerPEQRight = speakers.1
            engine.apply(config)
        }
        // The editor stays open and may keep auditioning: the committed EQ is
        // now what the engine has, so the audition restarts from it rather than
        // walking back from wherever the ramp had got to.
        if audition != nil { audition = PEQAuditionState(current: committedEQStages,
                                                         draft: committedEQStages,
                                                         globalText: globalPEQText,
                                                         speakerText: speakerPEQText) }
        save()
        saveSelectedProfile()
        append("Applied graphical PEQ edits and saved the profile.")
        return true
    }

    // MARK: - Live PEQ audition

    /// What the engine is being fed while the plot editor auditions a draft,
    /// and where it is headed.
    private struct PEQAuditionState {
        /// The EQ the engine has right now; `draft` is where it is walking to.
        var current: PEQAudition.Stages
        var draft: PEQAudition.Stages
        /// The draft in APO text, so the headroom readouts describe what is heard.
        var globalText: String
        var speakerText: String
        /// Set by Cancel/Close: walk back to the committed EQ and then let go.
        var ending = false
    }

    /// The committed EQ, as the processor renders it: three stages in
    /// physical-ear terms, flat while bypass is on.
    private var committedEQStages: PEQAudition.Stages {
        let speakers = speakerProfiles
        return .init(global: globalProfile, left: speakers.left, right: speakers.right)
    }

    /// The EQ the engine is actually rendering — the auditioned draft while the
    /// plot editor is live, the committed text otherwise.
    var auditionedEQStages: PEQAudition.Stages {
        guard let a = audition, !a.ending, !eqBypassed else { return committedEQStages }
        return a.draft
    }
    var auditionedPEQText: (global: String, speaker: String) {
        guard let a = audition, !a.ending else { return (globalPEQText, speakerPEQText) }
        return (a.globalText, a.speakerText)
    }

    /// Feed the plot editor's draft to the running processor. Nothing is written
    /// to `globalPEQText`, `speakerPEQText` or the profile library; only the
    /// render state changes, and `endPEQAudition` puts it back.
    ///
    /// Called on every drag event. The work is coalesced onto a 25 Hz tick, so a
    /// drag at display rate costs one `SoundMixProcessor.apply` per 40 ms rather
    /// than one per mouse event.
    func auditionPEQDraft(_ draft: PEQEditDraft) {
        guard state.isRunning, draft.warnings.isEmpty else { return }
        let stages = PEQAudition.Stages(global: draft.profile(.global),
                                        left: draft.profile(.left),
                                        right: draft.profile(.right))
        if audition == nil {
            audition = PEQAuditionState(current: committedEQStages, draft: stages,
                                        globalText: draft.globalText,
                                        speakerText: draft.speakerText)
            auditioningPEQ = true
        } else {
            audition?.draft = stages
            audition?.globalText = draft.globalText
            audition?.speakerText = draft.speakerText
            audition?.ending = false
        }
        startAuditionTimer()
    }

    /// Cancel, Close, or the audition toggle going off: walk the engine back to
    /// the committed EQ and release it. The ramp is the same bounded one the
    /// edits used, so undoing a big drag does not click either.
    func endPEQAudition() {
        guard audition != nil else { return }
        audition?.ending = true
        startAuditionTimer()
    }

    /// Drop the audition outright, for when a full configuration push is about
    /// to carry the committed EQ anyway.
    private func discardPEQAudition() {
        guard audition != nil else { return }
        audition = nil
        auditioningPEQ = false
        stopAuditionTimer()
    }

    private func auditionTick() {
        guard var a = audition else { stopAuditionTimer(); return }
        guard state.isRunning else { discardPEQAudition(); return }
        // Bypass still means bypass: an auditioned draft is heard only when the
        // EQ it belongs to is in circuit.
        let target = a.ending || eqBypassed ? committedEQStages : a.draft
        guard a.current != target else {
            // Converged. The timer idles until the next edit; an ending
            // audition has arrived at the pre-edit EQ and is finished.
            if a.ending { discardPEQAudition() } else { stopAuditionTimer() }
            return
        }
        a.current = a.current.stepped(toward: target)
        audition = a
        var config = engine.currentConfiguration
        config.globalPEQ = a.current.global
        config.speakerPEQLeft = a.current.left
        config.speakerPEQRight = a.current.right
        engine.apply(config)
    }

    private func startAuditionTimer() {
        guard auditionTimer == nil else { return }
        let timer = Timer(timeInterval: Self.auditionTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.auditionTick() }
        }
        // `.common` so the ticks keep arriving while a drag holds the run loop
        // in event-tracking mode, which is exactly when they are needed.
        RunLoop.main.add(timer, forMode: .common)
        auditionTimer = timer
    }

    private func stopAuditionTimer() {
        auditionTimer?.invalidate()
        auditionTimer = nil
    }

    func syncRecipeEditors() {
        let r = availableRecipes.first { $0.name == recipeName } ?? .reference
        lfeMode = r.lfeMode
        lfeCutoffText = String(format: "%.0f", r.lfeCutoffHz)
        lfeOrder = r.lfeFilterOrder
        lfeGainText = String(format: "%.2f", r.lfeGainDB)
    }

    func syncBinauralEditors() {
        let p = availableBinaurals.first { $0.name == binauralName } ?? .virtualSpeakers
        headRadiusText = String(format: "%.2f", p.headRadiusCM)
        bassCrossoverText = String(format: "%.0f", p.bassCrossoverHz)
        rearDampingText = String(format: "%.1f", p.rearDampingDB)
        elevationCueText = String(format: "%.1f", p.elevationCueDB)
        lfeMode = p.lfe.mode
        lfeCutoffText = String(format: "%.0f", p.lfe.cutoffHz)
        lfeOrder = p.lfe.filterOrder
        lfeGainText = String(format: "%.2f", p.lfe.gainDB)
    }

    /// Switching fold mode reloads the LFE editors from whichever fold is now
    /// in charge of them, so the LFE card always shows what is being rendered.
    func syncFoldEditors() {
        if foldIsBinaural { syncBinauralEditors() } else { syncRecipeEditors() }
    }

    func refreshDevices() {
        directory.refresh()
        devices = directory.devices
        append("Rescanned Core Audio devices — \(devices.count) present.")
    }

    func reloadPEQWarnings() {
        var w: [String] = []
        if !globalPEQText.isEmpty { w += APOParser.parse(globalPEQText).warnings.map { "Global PEQ: \($0)" } }
        if !speakerPEQText.isEmpty { w += APOParser.parse(speakerPEQText).warnings.map { "Speaker EQ: \($0)" } }
        peqWarnings = Array(w.prefix(6))
    }

    private func append(_ line: String) {
        let stamp = Self.formatter.string(from: Date())
        log.append(LogLine(text: "[\(stamp)] \(line)"))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log.removeAll() }

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var telemetryTick = 0

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.state.isRunning else { return }
                self.snapshot = self.engine.snapshot()
                self.telemetryTick += 1
                if self.telemetryTick % 15 == 0 { Telemetry.capture(self).write() }
            }
        }
    }

    /// A released model must not leave its timers scheduled on the run loop.
    deinit {
        meterTimer?.invalidate()
        auditionTimer?.invalidate()
    }

    /// Shown on the Speaker correction header while it is folded away.
    var speakerSectionSummary: String {
        guard !speakerPEQText.isEmpty else { return "none" }
        let s = speakerProfiles
        let l = s.left.activeFilterCount, r = s.right.activeFilterCount
        if l == 0 && r == 0 { return "none" }
        return l == r ? "\(l) filters per speaker" : "L \(l) · R \(r) filters"
    }

    // MARK: - EQ profile library

    var selectedProfile: EQProfile? {
        guard let id = selectedProfileID else { return nil }
        return profiles.first { $0.id == id }
    }

    /// Peak boost of what is currently being rendered — the headroom a profile
    /// costs. While the plot editor auditions a draft, that draft is what is
    /// being heard, so it is what this reports.
    var editorPeakBoostDB: Double {
        let rate = plotSampleRate
        let text = auditionedPEQText
        let draft = EQProfile(name: "", globalText: text.global, speakerText: text.speaker)
        return draft.peakBoostDB(sampleRate: rate)
    }

    func refreshProfiles() {
        library.reload()
        profiles = library.profiles
    }

    func selectProfile(_ profile: EQProfile) {
        selectedProfileID = profile.id
        profileNameDraft = profile.name
        profileNotesDraft = profile.notes
        globalPEQText = profile.globalText
        speakerPEQText = profile.speakerText
        measurementLeft = profile.measurementLeft
        measurementRight = profile.measurementRight
        target = profile.target
        profileDirty = false
        reloadPEQWarnings()
        applyLive()
        append("Loaded EQ profile “\(profile.name)”.")
    }

    /// New means new: a fresh profile named “New”, with no carried-over EQ
    /// text, measurements or target. Everything the previous selection put in
    /// the editors stays with the profile it came from.
    func newProfile() {
        do {
            let name = uniqueNewName()
            let p = try library.save(EQProfile(name: name))
            refreshProfiles()
            selectedProfileID = p.id
            profileNameDraft = p.name
            profileNotesDraft = p.notes
            globalPEQText = ""
            speakerPEQText = ""
            measurementLeft = nil
            measurementRight = nil
            target = nil
            profileDirty = false
            reloadPEQWarnings()
            applyLive()
            append("Created EQ profile “\(name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    private func uniqueNewName() -> String {
        let existing = Set(profiles.map(\.name))
        if !existing.contains("New") { return "New" }
        var n = 2
        while existing.contains("New \(n)") { n += 1 }
        return "New \(n)"
    }

    func saveSelectedProfile() {
        do {
            guard var p = selectedProfile else { newProfile(); return }
            p.name = profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? p.name : profileNameDraft
            p.notes = profileNotesDraft
            p.globalText = globalPEQText
            p.speakerText = speakerPEQText
            p.measurementLeft = measurementLeft
            p.measurementRight = measurementRight
            p.target = target
            let saved = try library.save(p)
            refreshProfiles()
            selectedProfileID = saved.id
            profileDirty = false
            append("Saved EQ profile “\(saved.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func duplicateSelectedProfile() {
        do {
            guard let p = selectedProfile else { return }
            let copy = try library.duplicate(p)
            refreshProfiles()
            selectedProfileID = copy.id
            profileNameDraft = copy.name
            append("Duplicated to “\(copy.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func deleteSelectedProfile() {
        do {
            guard let p = selectedProfile else { return }
            try library.delete(p)
            refreshProfiles()
            selectedProfileID = profiles.first?.id
            if let next = selectedProfile {
                profileNameDraft = next.name
                profileNotesDraft = next.notes
            } else {
                profileNameDraft = ""
                profileNotesDraft = ""
            }
            append("Deleted EQ profile “\(p.name)”.")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func importProfile(text: String, name: String, asSpeakerCorrection: Bool) {
        do {
            let p = try library.importAPO(text: text, name: name, asSpeakerCorrection: asSpeakerCorrection)
            refreshProfiles()
            selectProfile(p)
            append("Imported “\(name)” as \(asSpeakerCorrection ? "speaker correction" : "global PEQ").")
        } catch {
            errorMessage = error.localizedDescription
            append("EQ profile operation failed: \(error.localizedDescription)")
        }
    }

    func markProfileDirty() {
        guard let p = selectedProfile else { return }
        profileDirty = p.globalText != globalPEQText
            || p.speakerText != speakerPEQText
            || p.measurementLeft != measurementLeft
            || p.measurementRight != measurementRight
            || p.target != target
    }

    // MARK: Earphone measurement

    var hasMeasurement: Bool { measurementLeft != nil || measurementRight != nil }

    // MARK: PEQdB catalog (earphone picker)

    /// The PEQdB database behind the earphone picker: brands, models and the
    /// measured curves. Loaded lazily on first use, then served from disk cache.
    @Published private(set) var peqdbBrands: [PEQDBCatalog.Brand] = []
    @Published private(set) var peqdbLoading = false
    @Published private(set) var peqdbError: String?
    private let peqdb = PEQDBCatalog.shared

    /// Bring the catalog up once for the picker. A cached copy answers
    /// immediately; `refresh` forces a re-fetch from peqdb.com.
    func loadPEQDB(refresh: Bool = false) {
        guard !peqdbLoading else { return }
        peqdbLoading = true
        peqdbError = nil
        peqdb.load(refresh: refresh) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.peqdbLoading = false
                switch result {
                case .success:
                    self.peqdbBrands = self.peqdb.brands
                    self.append(String(format: "PEQdB catalog ready — %d brands, %d models.",
                                       self.peqdbBrands.count,
                                       self.peqdbBrands.reduce(0) { $0 + $1.models.count }))
                case .failure(let error):
                    self.peqdbError = error.localizedDescription
                    self.append("PEQdB catalog failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Fill one or both ears from a picked PEQdB variant, replacing whatever the
    /// profile had there. Same normalisation and dirty-marking as a file upload.
    func applyPEQDBModel(_ model: PEQDBCatalog.Model,
                         variant: PEQDBCatalog.Variant,
                         into side: EQProfile.Side) {
        let pair = peqdb.response(for: variant, model: model, into: side)
        guard pair.left != nil || pair.right != nil else {
            measurementError = "The PEQdB entry for “\(model.name)” could not be decoded."
            return
        }
        measurementLeft = pair.left
        measurementRight = pair.right
        measurementError = nil
        markProfileDirty()
        let name = PEQDBCatalog.curveName(model: model, variant: variant, channel: 0)
        if let l = pair.left, let r = pair.right {
            append(String(format: "Loaded PEQdB pair “%@” — %d points per ear.", name, l.points.count))
        } else {
            append(String(format: "Loaded PEQdB %@ measurement “%@” — %d points.",
                          side.label.lowercased(), name,
                          (pair.left ?? pair.right)?.points.count ?? 0))
        }
    }

    /// The single curve the Response plot and AutoTune work against: the dB mean
    /// of whatever ears were measured ("AverageR"). The per-ear curves the
    /// profile stores are untouched — this is a view over them.
    var averageMeasurement: FrequencyResponse? {
        FrequencyResponse.average([measurementLeft, measurementRight].compactMap { $0 },
                                  name: "AverageR")
    }

    func measurement(_ side: EQProfile.Side) -> FrequencyResponse? {
        side == .left ? measurementLeft : measurementRight
    }

    private func setMeasurement(_ value: FrequencyResponse?, for side: EQProfile.Side) {
        if side == .left { measurementLeft = value } else { measurementRight = value }
    }

    /// Load a measured response for one ear, exported from AutoEQ,
    /// oratory1990, a squig.link database or REW.
    ///
    /// A file with three columns (`frequency left right`) fills both ears at
    /// once, which is how most IEM measurements are published.
    func loadMeasurement(for side: EQProfile.Side) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a measured response for the \(side.label.lowercased()) ear. A three-column file fills both ears at once."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            measurementError = "Could not read \(url.lastPathComponent)."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent

        if let pair = FrequencyResponse.parsePair(text, name: name) {
            measurementLeft = pair.left.normalized()
            measurementRight = pair.right.normalized()
            measurementError = nil
            markProfileDirty()
            append(String(format: "Loaded “%@” as a matched pair — %d points per ear, %.0f Hz to %.0f Hz.",
                          name, pair.left.points.count, pair.left.range.low, pair.left.range.high))
            return
        }

        guard let parsed = FrequencyResponse.parse(text, name: name) else {
            measurementError = "\(url.lastPathComponent) does not look like a measurement — expected at least eight lines of “frequency level”, optionally with a third column for the right ear."
            return
        }
        setMeasurement(parsed.normalized(), for: side)
        measurementError = nil
        markProfileDirty()
        let r = parsed.range
        append(String(format: "Loaded %@ measurement “%@” — %d points, %.0f Hz to %.0f Hz.",
                      side.label.lowercased(), name, parsed.points.count, r.low, r.high))
    }

    func clearMeasurement(_ side: EQProfile.Side) {
        setMeasurement(nil, for: side)
        measurementError = nil
        markProfileDirty()
    }

    /// Exchange the two ears. A measurement imported before the split, or a
    /// file picked into the wrong slot, lands on the correct side without
    /// re-uploading it.
    func swapMeasurements() {
        let l = measurementLeft
        measurementLeft = measurementRight
        measurementRight = l
        markProfileDirty()
        append("Swapped the left and right earphone curves.")
    }

    /// Move one ear's curve to the other side, leaving this one empty.
    func moveMeasurement(from side: EQProfile.Side) {
        guard let curve = measurement(side) else { return }
        let other: EQProfile.Side = side == .left ? .right : .left
        setMeasurement(curve, for: other)
        setMeasurement(nil, for: side)
        markProfileDirty()
        append("Moved the curve to the \(other.label.lowercased()) ear.")
    }

    /// The bundled reference curves, loaded once from the app's Targets folder.
    /// An empty dictionary when the bundle folder is missing means the picker
    /// offers no built-in models, which the log line below records.
    static let bundledTargets: [BuiltInTarget: FrequencyResponse] = {
        guard let directory = BuiltInTarget.bundledDirectory() else { return [:] }
        var cache: [BuiltInTarget: FrequencyResponse] = [:]
        for target in BuiltInTarget.all {
            if let curve = try? target.load(from: directory) { cache[target] = curve }
        }
        return cache
    }()

    /// Load one of the bundled reference curves as the active target.
    func loadBuiltInTarget(_ model: BuiltInTarget) {
        guard let curve = Self.bundledTargets[model] else {
            measurementError = "The bundled target “\(model.name)” could not be loaded."
            return
        }
        target = curve
        measurementError = nil
        markProfileDirty()
        let r = curve.range
        append(String(format: "Loaded built-in target “%@” — %d points, %.0f Hz to %.0f Hz.",
                      model.name, curve.points.count, r.low, r.high))
    }

    /// Load a reference target — JM-1, a Harman variant, or a house curve.
    /// Nothing about the shape is assumed; it comes entirely from the file.
    func loadTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a target curve (frequency and level per line). JM-1 and the Harman targets are published in this format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            measurementError = "Could not read \(url.lastPathComponent)."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        guard let parsed = FrequencyResponse.parse(text, name: name) else {
            measurementError = "\(url.lastPathComponent) does not look like a target curve — expected at least eight lines of “frequency level”."
            return
        }
        target = parsed.normalized()
        measurementError = nil
        markProfileDirty()
        let r = parsed.range
        append(String(format: "Loaded target “%@” — %d points, %.0f Hz to %.0f Hz.",
                      name, parsed.points.count, r.low, r.high))
    }

    func clearTarget() {
        target = nil
        markProfileDirty()
        append("Removed the target curve.")
    }

    /// Worst deviation of the corrected result from the target (or from its own
    /// mean when no target is loaded), across both ears.
    func resultDeviationDB() -> Double? {
        let rate = plotSampleRate
        var worst: Double?
        for side in EQProfile.Side.allCases {
            guard let m = measurement(side) else { continue }
            let corrected = m.corrected(by: combinedEQCascade(side), sampleRate: rate)
            guard !corrected.isEmpty else { continue }
            if let t = target {
                let curve = FrequencyResponse(name: "", points: corrected).normalized()
                let ref = t.normalized()
                for p in curve.difference(from: ref) {
                    worst = max(worst ?? 0, abs(p.db))
                }
            } else {
                let sampled = FrequencyResponse(name: "", points: corrected).sampled()
                let mean = sampled.reduce(0) { $0 + $1.db } / Double(sampled.count)
                worst = max(worst ?? 0, sampled.reduce(0.0) { max($0, abs($1.db - mean)) })
            }
        }
        return worst
    }

    func clearAllMeasurements() {
        measurementLeft = nil
        measurementRight = nil
        measurementError = nil
        markProfileDirty()
    }

    /// Copy one ear's curve to the other, for a measurement published as a
    /// single averaged response.
    func mirrorMeasurement(from side: EQProfile.Side) {
        guard let source = measurement(side) else { return }
        let other: EQProfile.Side = side == .left ? .right : .left
        setMeasurement(FrequencyResponse(name: source.name, points: source.points), for: other)
        markProfileDirty()
        append("Copied the \(side.label.lowercased()) measurement to the \(other.label.lowercased()) ear.")
    }

    /// Everything the EQ does to one output, as a single cascade — the curve
    /// added to that ear's measurement. Global PEQ hits both; the speaker
    /// correction differs per side.
    func combinedEQCascade(_ side: EQProfile.Side) -> BiquadCascade {
        let rate = plotSampleRate
        let global = globalProfile.cascade(sampleRate: rate)
        let speaker = (side == .left ? speakerProfiles.left : speakerProfiles.right)
            .cascade(sampleRate: rate)
        return BiquadCascade(sections: global.sections + speaker.sections,
                             preGain: global.preGain * speaker.preGain)
    }

    // MARK: Portable import / export

    func exportProfiles(_ list: [EQProfile], suggestedName: String) {
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(EQProfileLibrary.fileExtension)"
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.message = list.count == 1
            ? "Export this EQ profile."
            : "Export all \(list.count) EQ profiles as one file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.exportData(list).write(to: url)
            append("Exported \(list.count) EQ profile\(list.count == 1 ? "" : "s") to \(url.lastPathComponent).")
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    func exportSelectedAsAPO(speakerCorrection: Bool) {
        guard let p = selectedProfile else { return }
        let text = library.exportAPO(p, speakerCorrection: speakerCorrection)
        guard !text.isEmpty else {
            errorMessage = "That profile has no \(speakerCorrection ? "speaker correction" : "global PEQ") to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name)\(speakerCorrection ? " speaker" : "").txt"
        panel.allowsOtherFileTypes = true
        panel.message = "Export as REW / Equalizer APO text."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            append("Exported “\(p.name)” as APO text.")
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
        }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        panel.message = "Import SoundMix EQ exports (.smeq) or REW / Equalizer APO text files."
        guard panel.runModal() == .OK else { return }
        var imported: [EQProfile] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "\(url.lastPathComponent) could not be read."
                continue
            }
            let base = url.deletingPathExtension().lastPathComponent
            do {
                imported += try library.importData(data, fallbackName: base)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        refreshProfiles()
        if let first = imported.first { selectProfile(first) }
        if !imported.isEmpty {
            append("Imported \(imported.count) EQ profile\(imported.count == 1 ? "" : "s").")
        }
    }

    func revealProfileFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.folderURL])
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var inputUID, outputUID, layoutName, recipeName: String
        var headroomMode: HeadroomMode
        var manualGainText: String
        var swapOutputs: Bool
        var lfeMode: LFEMode
        var lfeCutoffText, lfeGainText: String
        var lfeOrder: Int
        var limiterEnabled: Bool
        var limiterCeilingText, limiterReleaseText: String
        var globalPEQText, speakerPEQText: String
        var framesPerBuffer: Int
        var safetyBufferText: String
        var selectedProfileID: UUID?
        var eqBypassed: Bool?
        var speakerSectionCollapsed: Bool?
        // Added with the binaural fold; absent in settings written before it.
        var foldIsBinaural: Bool?
        var binauralName: String?
        var headRadiusText: String?
        var bassCrossoverText: String?
        var rearDampingText: String?
        var elevationCueText: String?
    }

    private static var settingsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundMix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    func save() {
        let s = Stored(inputUID: inputUID, outputUID: outputUID, layoutName: layoutName,
                       recipeName: recipeName, headroomMode: headroomMode,
                       manualGainText: manualGainText, swapOutputs: swapOutputs,
                       lfeMode: lfeMode, lfeCutoffText: lfeCutoffText, lfeGainText: lfeGainText,
                       lfeOrder: lfeOrder, limiterEnabled: limiterEnabled,
                       limiterCeilingText: limiterCeilingText, limiterReleaseText: limiterReleaseText,
                       globalPEQText: globalPEQText, speakerPEQText: speakerPEQText,
                       framesPerBuffer: framesPerBuffer, safetyBufferText: safetyBufferText,
                       selectedProfileID: selectedProfileID, eqBypassed: eqBypassed,
                       speakerSectionCollapsed: speakerSectionCollapsed,
                       foldIsBinaural: foldIsBinaural, binauralName: binauralName,
                       headRadiusText: headRadiusText, bassCrossoverText: bassCrossoverText,
                       rearDampingText: rearDampingText, elevationCueText: elevationCueText)
        do {
            let data = try JSONEncoder().encode(s)
            try data.write(to: Self.settingsURL, options: .atomic)
        } catch {
            append("Settings could not be saved: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        // Only restore a device selection that still exists, so a stale saved
        // path can never silently point at something that is gone.
        if devices.contains(where: { $0.uid == s.inputUID }) { inputUID = s.inputUID }
        if devices.contains(where: { $0.uid == s.outputUID }) { outputUID = s.outputUID }
        layoutName = s.layoutName
        recipeName = s.recipeName
        headroomMode = s.headroomMode
        manualGainText = s.manualGainText
        swapOutputs = s.swapOutputs
        lfeMode = s.lfeMode
        lfeCutoffText = s.lfeCutoffText
        lfeGainText = s.lfeGainText
        lfeOrder = s.lfeOrder
        limiterEnabled = s.limiterEnabled
        limiterCeilingText = s.limiterCeilingText
        limiterReleaseText = s.limiterReleaseText
        globalPEQText = s.globalPEQText
        speakerPEQText = s.speakerPEQText
        framesPerBuffer = s.framesPerBuffer
        safetyBufferText = s.safetyBufferText
        selectedProfileID = s.selectedProfileID
        eqBypassed = s.eqBypassed ?? false
        speakerSectionCollapsed = s.speakerSectionCollapsed ?? false
        // A settings file written before the binaural fold existed restores to
        // the amplitude matrix, exactly as it was saved.
        foldIsBinaural = s.foldIsBinaural ?? false
        binauralName = s.binauralName ?? BinauralProfile.virtualSpeakers.name
        headRadiusText = s.headRadiusText ?? headRadiusText
        bassCrossoverText = s.bassCrossoverText ?? bassCrossoverText
        rearDampingText = s.rearDampingText ?? rearDampingText
        elevationCueText = s.elevationCueText ?? elevationCueText
    }
}
