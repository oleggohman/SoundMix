import SwiftUI
import AppKit

/// Owns a separate native full-screen window, keeping the main controls available.
@MainActor
final class PEQPlotWindow: NSObject, NSWindowDelegate {
    static let shared = PEQPlotWindow()
    private var window: NSWindow?
    /// Held so the live audition can be released however the window goes away —
    /// the close button, ⌘W, or the editor's own Cancel.
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "SoundMix — PEQ editor"
        window.minSize = NSSize(width: 1040, height: 720)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PEQPlotEditor(model: model, close: { [weak self] in
            self?.window?.close()
        }).preferredColorScheme(.light))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
    }
    func windowWillClose(_ notification: Notification) {
        window = nil
        model?.endPEQAudition()
    }
}

struct PEQPlotEditor: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var draft: PEQEditDraft
    @State private var stage: PEQEditDraft.Stage = .global
    @State private var selected: Int? = nil
    @State private var hiddenEQ: Set<String> = []
    @State private var hiddenPreview: Set<String> = []
    @State private var message: String?
    /// Target selection only changes this preview; it never alters the profile or audio.
    @State private var targetChoice = "profile"
    private static let bundledTargets: [BuiltInTarget: FrequencyResponse] = {
        guard let directory = BuiltInTarget.bundledDirectory() else { return [:] }
        return Dictionary(uniqueKeysWithValues: BuiltInTarget.all.compactMap { target in
            guard let curve = try? target.load(from: directory) else { return nil }
            return (target, curve)
        })
    }()
    private var previewTarget: FrequencyResponse? {
        if targetChoice == "profile" { return model.target }
        guard let target = BuiltInTarget.withID(targetChoice) else { return nil }
        return Self.bundledTargets[target]
    }
    private var canShowTargetError: Bool { previewTarget != nil && model.hasMeasurement }
    /// Default on: an editor you tune by ear has to be audible while you tune it.
    @State private var auditionLive = true
    /// A profile the user picked while the draft still held unapplied edits.
    @State private var pendingProfile: EQProfile?
    /// The selection this draft was seeded from. Updated by a deliberate switch
    /// inside the editor, so only a change made elsewhere reads as a conflict.
    @State private var originalProfileID: UUID?
    /// Fixed at open and on a profile switch, never during a drag: a plot whose
    /// vertical range grew mid-drag would slide the point out from under the cursor.
    @State private var gainExtent: Double
    @State private var draftPeakBoostDB: Double

    init(model: AppModel, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        let draft = PEQEditDraft(global: model.globalPEQText, speaker: model.speakerPEQText,
                                 swapsOutputs: model.swapOutputs)
        _draft = State(initialValue: draft)
        _originalProfileID = State(initialValue: model.selectedProfileID)
        _gainExtent = State(initialValue: Self.extent(of: draft))
        _draftPeakBoostDB = State(initialValue: EQProfile(name: "", globalText: draft.globalText,
                                                          speakerText: draft.speakerText).peakBoostDB())
    }

    private static func extent(of draft: PEQEditDraft) -> Double {
        max(24, PEQEditDraft.Stage.allCases.flatMap { draft.profile($0).filters }
            .map { abs($0.gainDB) }.filter(\.isFinite).max() ?? 24) + 6
    }

    private var profile: PEQProfile { draft.profile(stage) }
    private var rate: Double { model.plotSampleRate }
    private var maxFrequency: Double { min(20_000, rate * 0.49) }
    private var selectedFilter: PEQFilter? {
        guard let selected, profile.filters.indices.contains(selected) else { return nil }
        return profile.filters[selected]
    }
    private var conflict: Bool {
        model.globalPEQText != draft.originalGlobal || model.speakerPEQText != draft.originalSpeaker
            || model.selectedProfileID != originalProfileID || model.swapOutputs != draft.swapsOutputs
    }
    private var editable: Bool { draft.warnings.isEmpty && !conflict }
    /// What the draft costs in headroom, which a preamp or a wide boost changes
    /// the moment it is dragged. Recomputed when the draft changes rather than
    /// when the view redraws, which the running meters do thirty times a second.
    private func measureDraftHeadroom() {
        draftPeakBoostDB = EQProfile(name: "", globalText: draft.globalText,
                                     speakerText: draft.speakerText).peakBoostDB(sampleRate: rate)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                header
                if !draft.warnings.isEmpty {
                    Text("This EQ contains unsupported directives. Edit those in the text editor before using graphical edits: " + draft.warnings.joined(separator: "; "))
                        .foregroundStyle(CZ.Color.red)
                }
                if conflict {
                    HStack {
                        Text("The EQ changed in the main window, so this draft no longer describes it.")
                            .foregroundStyle(CZ.Color.red)
                        Button("Discard draft and reload") { reseedFromModel() }
                            .help("Take the main window's current EQ as the new starting point")
                    }
                }
                if model.eqBypassed {
                    Text("EQ is bypassed. This is a preview of your filters; turn bypass off in the main window to hear applied changes.")
                        .foregroundStyle(CZ.Color.orange)
                }
                ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EQ gain (dB) · drag points for gain and frequency · hold Shift to lock one axis")
                            .font(.system(size: 14, weight: .medium))
                        ResponseCurve(traces: [
                            .fromProfile("Reference · before edits", CZ.Color.orange,
                                         draft.referenceProfile(stage), sampleRate: rate, dashed: true),
                            .fromProfile("Draft · \(stage.rawValue)", CZ.Color.blue,
                                         profile, sampleRate: rate, emphasised: true)],
                                      height: max(180, (geo.size.height - 350) * 0.6), hidden: $hiddenEQ,
                                      editPoints: profile.filters.enumerated().map {
                                          .init(id: $0.offset, frequency: $0.element.frequency,
                                                gainDB: $0.element.gainDB, enabled: $0.element.enabled)
                                      }, selectedPoint: selected, fixedRange: -gainExtent...gainExtent,
                                      showsReadout: false,
                                      onSelectPoint: { selected = $0 },
                                      onChangeBand: { index, gain, frequency in
                                          selected = index
                                          edit { $0.setBand(at: index, for: stage, gainDB: gain,
                                                            frequency: frequency,
                                                            maxFrequency: maxFrequency) }
                                      },
                                      maxDragFrequency: maxFrequency, referenceLineDB: 0)
                            .disabled(!editable)
                        HStack {
                            Text("Draft result · normalized response / EQ gain (dB)")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            Picker("Target", selection: $targetChoice) {
                                Text("Profile target").tag("profile")
                                Text("None").tag("none")
                                ForEach(BuiltInTarget.all) { Text($0.name).tag($0.rawValue) }
                            }
                            .frame(maxWidth: 380)
                            .onChange(of: targetChoice) { _, _ in
                                hiddenPreview.removeAll()
                            }
                            Text("Visual reference only · EQ unchanged")
                                .font(.system(size: 12))
                                .foregroundStyle(CZ.Color.mediumGray)
                        }
                        if let chosen = BuiltInTarget.withID(targetChoice), Self.bundledTargets[chosen] == nil {
                            Text("The bundled target could not be loaded. Rebuild or reinstall the app.")
                                .foregroundStyle(CZ.Color.red)
                        } else if previewTarget != nil && !model.hasMeasurement {
                            Text("Target shown for reference. Load an earphone measurement to compare the corrected response with it.")
                                .font(.system(size: 12)).foregroundStyle(CZ.Color.mediumGray)
                        }
                        ResponseCurve(traces: ResponsePlotTraces.make(model: model, rate: rate,
                                          global: draft.profile(.global),
                                          speakers: (draft.profile(.left), draft.profile(.right)), target: previewTarget),
                                      height: max(120, (geo.size.height - 350) * 0.4),
                                      hidden: $hiddenPreview)
                    }
                    inspector(listHeight: min(480, max(280, geo.size.height * 0.42)))
                        .frame(width: min(360, max(320, geo.size.width * 0.25)))
                }
                .padding(.vertical, 4)
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(CZ.Color.paleBlue)
            .foregroundStyle(CZ.Color.darkBlue)
        }
        .onDisappear { model.endPEQAudition() }
        .confirmationDialog("Switch EQ profile?",
                            isPresented: Binding(get: { pendingProfile != nil },
                                                 set: { if !$0 { pendingProfile = nil } }),
                            presenting: pendingProfile) { profile in
            Button("Apply edits, then switch") {
                if applyDraft() { switchProfile(to: profile) }
                pendingProfile = nil
            }
            Button("Discard edits and switch", role: .destructive) {
                switchProfile(to: profile)
                pendingProfile = nil
            }
            Button("Stay here", role: .cancel) { pendingProfile = nil }
        } message: { profile in
            Text("This draft has edits that have not been applied. Loading “\(profile.name)” replaces the editors with that profile's EQ.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PEQ plot editor").font(.system(size: 24, weight: .semibold))
                Text("Edits are heard as you make them but stay a draft. Apply updates the current EQ and saves the profile.")
                    .font(.system(size: 12))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    Picker("Profile", selection: profileSelection) {
                        if model.selectedProfileID == nil {
                            Text("No profile").tag(UUID?.none)
                        }
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(width: 240)
                        .disabled(model.profiles.isEmpty)
                        .help("Load another EQ profile without leaving the editor")
                    Picker("Edit", selection: $stage) {
                        ForEach(PEQEditDraft.Stage.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 210)
                        .onChange(of: stage) { _, _ in selected = nil; hiddenEQ.removeAll() }
                }
                Toggle("Audition live", isOn: $auditionLive)
                    .toggleStyle(.switch)
                    .help("Send the draft to the running processor as you edit. Nothing is written to the profile until Apply.")
                    .onChange(of: auditionLive) { _, on in
                        if on { pushAudition() } else { model.endPEQAudition() }
                    }
            }
        }
    }

    /// Reads the main window's selection, but a change goes through the
    /// unapplied-edits question rather than straight into the library.
    private var profileSelection: Binding<UUID?> {
        Binding(get: { model.selectedProfileID }, set: { requestProfileSwitch(to: $0) })
    }

    private func requestProfileSwitch(to id: UUID?) {
        guard let id, id != model.selectedProfileID,
              let profile = model.profiles.first(where: { $0.id == id }) else { return }
        if draft.hasChanges && draft.warnings.isEmpty {
            pendingProfile = profile
        } else {
            switchProfile(to: profile)
        }
    }

    /// Load another profile and re-seed the draft from it. `selectProfile` pushes
    /// the new EQ to the engine and drops any audition, and re-seeding keeps the
    /// conflict guard pointed at external changes only.
    private func switchProfile(to profile: EQProfile) {
        model.selectProfile(profile)
        reseedFromModel()
        message = "Loaded “\(profile.name)”. Its measurement and target are in the result plot."
    }

    /// Start again from whatever the main window now holds, which is both what a
    /// deliberate profile switch needs and the way out of a conflict.
    private func reseedFromModel() {
        model.endPEQAudition()
        draft = PEQEditDraft(global: model.globalPEQText, speaker: model.speakerPEQText,
                             swapsOutputs: model.swapOutputs)
        originalProfileID = model.selectedProfileID
        gainExtent = Self.extent(of: draft)
        measureDraftHeadroom()
        selected = nil
        hiddenEQ.removeAll()
        message = "Reloaded from the main window."
    }

    private func inspector(listHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Add band", systemImage: "plus") {
                    var next = 0
                    edit {
                        var p = $0.profile(stage)
                        p.filters.append(PEQFilter(frequency: 1000, gainDB: 0, q: 1))
                        $0.setProfile(p, for: stage)
                        next = p.filters.count - 1
                    }
                    selected = next
                }
                Button("Delete", systemImage: "trash") {
                    if let selected { remove(selected) }
                }.disabled(selectedFilter == nil)
                Button("AutoTune", systemImage: "wand.and.rays") { runAutoTune() }
                    .disabled(previewTarget == nil || model.averageMeasurement == nil)
                    .help("Design up to 30 peaking bands that flatten the averaged measurement onto the chosen target, then write them into this stage as a draft. Reset restores what was there.")
            }
            numberField("Preamp (dB)", value: profile.preampDB, limits: -60...24) { value in
                edit { var p = $0.profile(stage); p.preampDB = value; $0.setProfile(p, for: stage) }
            }
            if let filter = selectedFilter {
                Divider()
                Text("Band \((selected ?? 0) + 1)").font(.headline)
                Toggle("Enabled", isOn: Binding(get: { filter.enabled }, set: { value in updateFilter { $0.enabled = value } }))
                Picker("Type", selection: Binding(get: { filter.kind }, set: { value in updateFilter { $0.kind = value } })) {
                    Text("Peak").tag(PEQFilter.Kind.peaking)
                    Text("Low shelf").tag(PEQFilter.Kind.lowShelf)
                    Text("High shelf").tag(PEQFilter.Kind.highShelf)
                }
                numberField("Frequency (Hz)", value: filter.frequency, limits: 20...maxFrequency) { value in updateFilter { $0.frequency = value } }
                numberField("Gain (dB)", value: filter.gainDB, limits: -24...24) { value in updateFilter { $0.gainDB = value } }
                numberField("Q", value: filter.q, limits: 0.1...20) { value in updateFilter { $0.q = value } }
                Slider(value: Binding(get: { filter.q }, set: { value in updateFilter { $0.q = value } }), in: 0.1...20)
                    .accessibilityLabel("Band Q")
            } else {
                Text("Select a numbered point, or add a band. Drag a point for gain and frequency, holding Shift to lock it to one axis. Bands keep their numbering: dragging one past another does not renumber either.")
                    .font(.system(size: 14))
            }
            Divider()
            bandList(height: listHeight)
        }
        .padding(16)
        .background(CZ.Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CZ.Color.ghostGray))
        .disabled(!editable)
    }

    /// Each row carries its own mute and delete, and the list takes the Delete
    /// key for the selected row once it has focus.
    private func bandList(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bands").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(profile.filters.count) bands")
                    .font(.system(size: 12)).foregroundStyle(CZ.Color.mediumGray)
            }
            if profile.filters.isEmpty {
                Text("No bands yet. Choose Add band to start shaping the EQ.")
                    .font(.system(size: 13)).foregroundStyle(CZ.Color.mediumGray)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(profile.filters.enumerated()), id: \.offset) { index, filter in
                                bandRow(index, filter)
                                    .id(index)
                            }
                        }.padding(4)
                    }
                    .frame(height: height)
                    .scrollIndicators(.visible)
                    .onChange(of: selected) { _, index in
                        if let index { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
                    }
                }
            }
            Text("Select a band · speaker toggles on/off · Delete removes it")
                .font(.system(size: 11)).foregroundStyle(CZ.Color.mediumGray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { if let selected { remove(selected) } }
        .help("Select a band and press Delete to remove it. Reset restores deleted bands.")
    }

    private func bandRow(_ index: Int, _ filter: PEQFilter) -> some View {
        HStack(spacing: 4) {
            Button { selected = index } label: {
                HStack(spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 26, height: 26)
                        .background(selected == index ? CZ.Color.blue : CZ.Color.paleBlue)
                        .foregroundStyle(selected == index ? CZ.Color.white : CZ.Color.darkBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "%.0f Hz", filter.frequency))
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(String(format: "%+.1f dB", filter.gainDB) + (filter.enabled ? "" : " · OFF"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(CZ.Color.mediumGray)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button {
                selected = index
                edit { $0.setEnabled(!filter.enabled, at: index, for: stage) }
            } label: {
                Image(systemName: filter.enabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(filter.enabled ? CZ.Color.darkBlue : CZ.Color.mediumGray)
                    .frame(width: 32, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(filter.enabled ? "Disable" : "Enable") band \(index + 1)")
            .help(filter.enabled ? "Silence band \(index + 1) without deleting it" : "Enable band \(index + 1)")
            Button { remove(index) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14)).foregroundStyle(CZ.Color.red)
                    .frame(width: 32, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete band \(index + 1)")
            .help("Delete band \(index + 1). Reset restores it.")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(selected == index ? CZ.Color.lightestBlue : CZ.Color.paleBlue.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(selected == index ? CZ.Color.blue : Color.clear, lineWidth: 1))
    }

    /// Removal keeps the list usable: the band that slid into the gap is
    /// selected, or the new last one, rather than nothing at all.
    private func remove(_ index: Int) {
        let count = profile.filters.count
        guard count > 0 else { return }
        edit { $0.removeFilter(at: index, for: stage) }
        selected = PEQEditDraft.selectionAfterRemoval(of: index, count: count)
    }

    private func numberField(_ title: String, value: Double, limits: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            TextField(title, value: Binding(get: { value }, set: { newValue in
                guard newValue.isFinite else { return }
                set(min(limits.upperBound, max(limits.lowerBound, newValue)))
            }), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(message ?? "Changes are a draft. Applying rewrites edited EQ text in APO format.")
                    .font(.system(size: 12))
                Text(headroomLine).font(.system(size: 11)).foregroundStyle(CZ.Color.mediumGray)
            }
            Spacer()
            Button("Reset") {
                edit { $0.reset() }
                selected = nil
                message = "Unapplied edits reset."
            }
            .disabled(!draft.hasChanges || conflict)
            .help("Discard all edits since opening the editor or the last Apply, deletions included")
            Button(draft.hasChanges ? "Cancel" : "Close", action: close).keyboardShortcut(.cancelAction)
            Button("Apply") { _ = applyDraft() }
                .buttonStyle(.borderedProminent)
                .disabled(!draft.hasChanges || !editable)
            Button("Apply & close") { if applyDraft() { close() } }
                .disabled(!draft.hasChanges || !editable)
        }
    }

    private var headroomLine: String {
        let boost = String(format: "%+.1f dB", draftPeakBoostDB)
        guard model.state.isRunning else {
            return "Draft peak EQ boost \(boost). Start playback to hear edits as you make them."
        }
        let auditioning = auditionLive && editable
        return "Draft peak EQ boost \(boost) · limiter \(model.limiterStatus) · "
            + (auditioning ? "auditioning this draft; Cancel restores the EQ you started with"
                           : "not auditioning — the engine is rendering the applied EQ")
    }

    @discardableResult
    private func applyDraft() -> Bool {
        guard editable else { return false }
        guard model.applyPEQDraft(draft) else {
            message = "The EQ changed in the main window. Close and reopen this editor."
            return false
        }
        draft.acceptChanges()
        message = "Applied and saved to the profile. You can keep editing; Apply saves again."
        return true
    }

    private func updateFilter(_ change: @escaping (inout PEQFilter) -> Void) {
        guard let selected else { return }
        edit {
            var p = $0.profile(stage)
            guard p.filters.indices.contains(selected) else { return }
            change(&p.filters[selected])
            $0.setProfile(p, for: stage)
        }
    }

    /// The one way the draft changes: edit, then audition. Routing every
    /// mutation through here is what keeps the sound and the picture in step.
    private func edit(_ change: (inout PEQEditDraft) -> Void) {
        guard editable else { return }
        change(&draft)
        message = nil
        measureDraftHeadroom()
        pushAudition()
    }

    private func pushAudition() {
        guard auditionLive, editable else { return }
        model.auditionPEQDraft(draft)
    }

    /// One click from measurement to correction: design peaking bands against
    /// the error between the chosen target and the averaged measurement, and
    /// write them into the selected stage as an ordinary draft change — so
    /// audition, the headroom readout, Apply and Reset all keep working.
    private func runAutoTune() {
        guard editable, let measurement = model.averageMeasurement,
              let target = previewTarget else { return }
        let bands = AutoTune.bands(matching: measurement, to: target,
                                   sampleRate: rate, maxFrequency: maxFrequency)
        guard !bands.isEmpty else {
            message = "AutoTune found nothing worth correcting — the averaged measurement already tracks the target within 0.5 dB."
            return
        }
        edit {
            var p = $0.profile(stage)
            // A complete correction of the raw measurement: replace, don't stack.
            p.filters = bands
            $0.setProfile(p, for: stage)
        }
        selected = nil
        message = "AutoTune wrote \(bands.count) bands into \(stage.rawValue). Drag points to refine, then Apply. Reset restores the previous EQ."
    }
}
