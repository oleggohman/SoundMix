import SwiftUI
import UniformTypeIdentifiers

// MARK: - Devices

struct DevicesPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            if let note = MicrophoneAccess.explanation(for: model.micStatus) {
                CZCard(title: "Microphone access") {
                    CZAlert(kind: model.micStatus == .notDetermined ? .info : .error, message: note)
                    if model.micStatus == .denied {
                        CZButton(title: "Open System Settings", icon: "gear",
                                 variant: .secondary, size: .small) { MicrophoneAccess.openSettings() }
                    }
                }
            }

            CZCard(title: "Input",
                   subtitle: "The interface carrying the bed. \(model.layout.name) needs \(model.layout.requiredInputChannels) channels.") {
                CZSelect(label: "Input device",
                         selection: Binding(get: { model.inputUID }, set: { uid in
                             model.inputUID = uid
                             model.refreshDevices()
                         }),
                         options: model.compatibleInputs.map { ($0.uid, deviceTitle($0)) })
                if let d = model.inputDevice {
                    DeviceDetail(device: d, needed: model.layout.requiredInputChannels, isInput: true)
                    DeviceVolumeView(device: d, isInput: true).id("input-\(d.id)")
                }
            }

            CZCard(title: "Output",
                   subtitle: "The stereo pair the bed folds down to. Devices with more than two outputs are fine — the first pair is used.") {
                CZSelect(label: "Output device",
                         selection: Binding(get: { model.outputUID }, set: { uid in
                             model.outputUID = uid
                             model.refreshDevices()
                         }),
                         options: model.compatibleOutputs.map { ($0.uid, deviceTitle($0)) })
                if let d = model.outputDevice {
                    DeviceDetail(device: d, needed: 2, isInput: false)
                    DeviceVolumeView(device: d, isInput: false).id("output-\(d.id)")
                }
                CZToggleRow(title: "Swap physical left and right",
                            subtitle: "Also flips which half of a stereo speaker-EQ file goes to which speaker.",
                            isOn: $model.swapOutputs)
            }

            CZCard(title: "Engine") {
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZSelect(label: "Frames per buffer",
                             selection: $model.framesPerBuffer,
                             options: [32, 64, 128, 256, 512, 1024].map { ($0, "\($0)") },
                             help: "Smaller is lower latency and more CPU.")
                        .frame(width: 180)
                    CZField(label: "Device-clock safety buffer", text: $model.safetyBufferText,
                            suffix: "ms",
                            help: "Absorbs drift between the two devices' clocks.",
                            width: 180)
                    Spacer()
                }
                HStack {
                    CZToggleRow(title: "Show devices that cannot be used",
                                subtitle: "Lists interfaces with too few channels for the current layout.",
                                isOn: $model.showIncompatibleDevices)
                    Spacer(minLength: CZ.Spacing.xl)
                    CZButton(title: "Rescan", icon: "arrow.clockwise",
                             variant: .secondary, size: .small) { model.refreshDevices() }
                }
            }

            CZCard(title: "System audio",
                   subtitle: "Channel counts, sample rates and aggregate devices are set by macOS, not here.") {
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Sound settings", icon: "speaker.wave.2",
                             variant: .secondary, size: .small) { SystemLinks.openSoundSettings() }
                    CZButton(title: "Audio MIDI Setup", icon: "pianokeys",
                             variant: .secondary, size: .small) { SystemLinks.openAudioMIDISetup() }
                    CZButton(title: "Microphone privacy", icon: "mic",
                             variant: .transparent, size: .small) { SystemLinks.openMicrophoneSettings() }
                    Spacer()
                }
                Text("Use Audio MIDI Setup to change a device's channel count or sample rate, or to build an aggregate device when the bed and the speakers live on different interfaces.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refreshDevices() }
    }

    private func deviceTitle(_ d: AudioDevice) -> String {
        var parts = [d.name]
        parts.append("· \(d.channelSummary)")
        if !d.transportType.isEmpty { parts.append("· \(d.transportType)") }
        return parts.joined(separator: " ")
    }
}

private struct DeviceVolumeView: View {
    let device: AudioDevice
    let isInput: Bool
    @State private var volume = DeviceVolume.State(value: nil, writable: false, channelControls: 0)
    @State private var error: String?
    @State private var dragging = false

    private var channels: Int { isInput ? device.inputChannels : device.outputChannels }
    private var title: String { isInput ? "Input device volume" : "Output device volume" }

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            HStack {
                Text(title).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Spacer()
                Text(volume.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable")
                    .font(CZ.Typography.mono(12))
            }
            Slider(value: Binding(get: { volume.value ?? 0 }, set: { value in
                dragging = true
                let device = self.device, isInput = self.isInput, channels = self.channels
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try DeviceVolume.set(value, device: device.id, isInput: isInput, channels: channels)
                        let state = DeviceVolume.read(device: device.id, isInput: isInput, channels: channels)
                        DispatchQueue.main.async {
                            volume = state
                            error = nil
                            dragging = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.error = error.localizedDescription
                            dragging = false
                        }
                    }
                }
            }), in: 0...1, onEditingChanged: { dragging = $0 })
                .disabled(!volume.writable)
                .accessibilityLabel(title)
                .tint(CZ.Color.blue)
            Text(volume.writable
                 ? "Changes macOS volume for this device, including other apps.\(volume.channelControls > 0 ? " Links writable channel controls while preserving balance." : "")"
                 : "This device does not expose writable macOS volume. Use its hardware controls, source-app volume, or SoundMix manual gain under Downmix.")
                .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                .fixedSize(horizontal: false, vertical: true)
            if let error { CZAlert(kind: .error, message: error) }
        }
        .task {
            // Core Audio property reads are synchronous IPC; keep them off the
            // main thread so a slow device cannot stutter the interface.
            while !Task.isCancelled {
                let device = self.device, isInput = self.isInput, channels = self.channels
                let state = await Task.detached(priority: .utility) {
                    DeviceVolume.read(device: device.id, isInput: isInput, channels: channels)
                }.value
                if !dragging { volume = state }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
    }
}

private struct DeviceDetail: View {
    let device: AudioDevice
    let needed: Int
    let isInput: Bool

    private var available: Int { isInput ? device.inputChannels : device.outputChannels }
    private var ok: Bool { available >= needed }

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            HStack(spacing: CZ.Spacing.sm) {
                CZPill(text: "\(available) ch", tint: ok ? CZ.Color.blue : CZ.Color.red)
                CZPill(text: "\(Int(device.nominalSampleRate)) Hz", tint: CZ.Color.mediumGray)
                if !device.transportType.isEmpty { CZPill(text: device.transportType, tint: CZ.Color.mediumGray) }
                if device.isDefaultInput { CZPill(text: "system input", tint: CZ.Color.purple) }
                if device.isDefaultOutput { CZPill(text: "system output", tint: CZ.Color.purple) }
            }
            if !ok {
                CZAlert(kind: .error,
                        message: "“\(device.name)” exposes \(available) \(isInput ? "input" : "output") channel\(available == 1 ? "" : "s") but \(needed) are needed.")
            }
        }
    }
}

// MARK: - Downmix

/// The binaural settings, shown in place of the matrix when that fold is active.
private struct BinauralCard: View {
    @EnvironmentObject var model: AppModel

    private var profile: BinauralProfile { model.workingBinaural }
    private var isCrossfeed: Bool { profile.model == .crossfeed }

    var body: some View {
        CZCard(title: "Binaural", subtitle: profile.notes) {
            CZSelect(label: "Filter bank", selection: $model.binauralName,
                     options: model.availableBinaurals.map { ($0.name, $0.name) },
                     help: profile.model.explanation)
                .onChange(of: model.binauralName) { _, _ in model.syncBinauralEditors() }

            HStack(alignment: .bottom, spacing: CZ.Spacing.lg) {
                CZField(label: "Head radius", text: $model.headRadiusText, suffix: "cm", width: 120)
                    .disabled(isCrossfeed)
                CZField(label: "Bass crossover", text: $model.bassCrossoverText, suffix: "Hz", width: 140)
                CZField(label: "Rear damping", text: $model.rearDampingText, suffix: "dB", width: 130)
                    .disabled(isCrossfeed)
                CZField(label: "Elevation cue", text: $model.elevationCueText, suffix: "dB", width: 130)
                    .disabled(isCrossfeed)
                Spacer()
            }

            Text(isCrossfeed
                 ? "Crossfeed has no head model, so only the bass split applies. Set the crossover to 0 to switch it off."
                 : "Head radius sets both the inter-aural delay and the corner of the head shadow. Below the bass crossover the fold collapses to the centre, because the ear takes no direction from there and per-ear filtering of the bass only combs; 0 switches the split off. Rear damping is the front/back cue a sphere cannot provide on its own, and the elevation cue is a pinna notch that climbs with height.")
                .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                .fixedSize(horizontal: false, vertical: true)

            if let bank = model.displayedBank {
                HRIRTable(bank: bank, layout: model.layout)
                Text(String(format: "%d taps per ear per channel at %.0f kHz, 15 convolutions per block, %.2f ms of bulk delay.",
                            bank.tapCount, bank.sampleRate / 1000,
                            Double(bank.referenceDelaySamples) / bank.sampleRate * 1000))
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
            }

            CZAlert(kind: .warning,
                    message: "For headphones only. On speakers this will sound wrong. It also colours the timbre by design, and because the head is synthetic rather than measured from you, front/back confusion and an in-head image are normal rather than faults.")
        }
    }
}

/// What the filter bank does to each mapped channel: where it is, how late it
/// reaches the far ear, and at what level it reaches each one.
private struct HRIRTable: View {
    let bank: HRIRBank
    let layout: LayoutPreset

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bed channel").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Spacer()
                ForEach(["Direction", "ITD", "→ L", "→ R"], id: \.self) { head in
                    Text(head).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                        .frame(width: head == "Direction" ? 120 : 76, alignment: .trailing)
                }
            }
            .padding(.vertical, CZ.Spacing.xs)
            Divider()
            ForEach(layout.activeChannels.filter { $0 != .lfe }, id: \.rawValue) { ch in
                HStack {
                    Text("\(ch.shortName)  ·  \(ch.longName)")
                        .font(CZ.Typography.bodySmall).foregroundStyle(CZ.Color.defaultText)
                    Spacer()
                    Text(String(format: "%.0f° / %.0f°", ch.direction.azimuthDeg, ch.direction.elevationDeg))
                        .font(CZ.Typography.mono(12)).foregroundStyle(CZ.Color.mediumGray)
                        .frame(width: 120, alignment: .trailing)
                    Text(String(format: "%+.0f µs", bank.itdMicroseconds(ch)))
                        .font(CZ.Typography.mono(12)).foregroundStyle(CZ.Color.mediumGray)
                        .frame(width: 76, alignment: .trailing)
                    Text(String(format: "%+.1f dB", bank.gainDB(ch, ear: HRIRBank.leftEar)))
                        .font(CZ.Typography.mono(12)).foregroundStyle(CZ.Color.darkBlue)
                        .frame(width: 76, alignment: .trailing)
                    Text(String(format: "%+.1f dB", bank.gainDB(ch, ear: HRIRBank.rightEar)))
                        .font(CZ.Typography.mono(12)).foregroundStyle(CZ.Color.darkBlue)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.vertical, 3)
                Divider().opacity(0.4)
            }
            if layout.activeChannels.contains(.lfe) {
                HStack {
                    Text("LFE  ·  not filtered — direction is not carried down there")
                        .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
    }
}

struct SoundMixPanel: View {
    @EnvironmentObject var model: AppModel

    private var config: ProcessorConfiguration { model.configuration }
    private var matrix: SoundMixMatrix { config.effectiveMatrix }

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            CZCard(title: "Source layout",
                   subtitle: "Which bed slots the device channels feed. Unmapped slots stay silent.") {
                CZSelect(label: "Layout", selection: $model.layoutName,
                         options: LayoutPreset.all.map { ($0.name, "\($0.name)  ·  \($0.requiredInputChannels) ch") })
                ChannelMapStrip(layout: model.layout)
            }

            CZCard(title: "Fold",
                   subtitle: "How the bed becomes two channels: a matrix of gains, which is right for speakers, or a head-related filter bank, which is right for headphones.") {
                CZSelect(label: "Fold mode", selection: $model.foldIsBinaural,
                         options: [(false, "Amplitude matrix  ·  speakers"),
                                   (true, "Binaural / HRTF  ·  headphones")],
                         help: model.foldIsBinaural
                            ? "Every bed channel is filtered with the response of a head at that loudspeaker angle, so the channels arrive from their own directions instead of being panned between two points. Headphones only — on speakers the crosstalk between them undoes the effect."
                            : "Every bed channel is scaled by a coefficient and summed. Correct for speakers, and the only mode that can reproduce the original app.")
                    .onChange(of: model.foldIsBinaural) { _, _ in model.syncFoldEditors() }
            }

            if model.foldIsBinaural {
                BinauralCard()
            } else {
                CZCard(title: "Matrix",
                       subtitle: (model.availableRecipes.first { $0.name == model.recipeName })?.notes ?? "") {
                    CZSelect(label: "Downmix recipe", selection: $model.recipeName,
                             options: model.availableRecipes.map { ($0.name, $0.name) })
                        .onChange(of: model.recipeName) { _, _ in model.syncRecipeEditors() }
                    MatrixTable(matrix: matrix, layout: model.layout)
                }
            }

            CZCard(title: "Headroom",
                   subtitle: "The original app ships a blunt −9.5 dB preamp. These numbers are computed from the matrix you actually selected.") {
                CZSelect(label: "Automatic trim", selection: $model.headroomMode,
                         options: HeadroomMode.allCases.map { ($0, $0.label) },
                         help: model.headroomMode.explanation)
                HStack(alignment: .top, spacing: CZ.Spacing.xl) {
                    stat("Worst-case gain", String(format: "%+.2f dB", config.foldPeakGainDB),
                         "Every mapped channel at full scale at once.")
                    stat("Uncorrelated gain", String(format: "%+.2f dB", config.foldPowerGainDB),
                         "Realistic level change for normal material.")
                    stat("Automatic trim", String(format: "%+.2f dB", config.automaticTrimDB), nil)
                    stat("Total applied", String(format: "%+.2f dB", config.totalTrimDB), nil)
                }
                HStack(alignment: .bottom, spacing: CZ.Spacing.md) {
                    CZField(label: "Additional manual gain", text: $model.manualGainText, suffix: "dB", width: 160)
                    Button("−1 dB") { model.adjustManualGain(by: -1) }
                    Button("+1 dB") { model.adjustManualGain(by: 1) }
                }
                Text(model.gainBreakdown)
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The limiter only reduces peaks. Use small gain steps for quiet material; buttons apply immediately during playback.")
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                    .fixedSize(horizontal: false, vertical: true)
                if config.foldPeakGainDB > 0 && model.headroomMode == .none && !model.limiterEnabled {
                    CZAlert(kind: .warning,
                            message: String(format: "With no automatic trim and no limiter this fold can reach %+.1f dB — the same overload the original app has.", config.foldPeakGainDB + (Double(model.manualGainText) ?? 0)))
                }
                if model.foldIsBinaural && model.headroomMode == .peakSafe {
                    CZAlert(kind: .info,
                            message: "Peak-safe bounds a filter bank by the sum of its absolute taps, which is a far deeper cut than the same bound on a matrix. Power-preserving is the usable setting here; the limiter catches what is left.")
                }
            }

            CZCard(title: "LFE",
                   subtitle: "The original fixes this at a 4th-order 125 Hz Butterworth with a +7.100 dB coefficient. Here it is adjustable, and the dry path is delayed to the filter's own group delay so the bass still sums in phase.") {
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZSelect(label: "Mode", selection: $model.lfeMode,
                             options: LFEMode.allCases.map { ($0, $0.label) })
                        .frame(width: 200)
                    CZField(label: "Cut-off", text: $model.lfeCutoffText, suffix: "Hz", width: 120)
                        .disabled(model.lfeMode != .lowPass)
                    CZSelect(label: "Slope", selection: $model.lfeOrder,
                             options: [(2, "12 dB/oct"), (4, "24 dB/oct"), (6, "36 dB/oct"), (8, "48 dB/oct")])
                        .frame(width: 150)
                        .disabled(model.lfeMode != .lowPass)
                    CZField(label: "LFE gain", text: $model.lfeGainText, suffix: "dB", width: 120)
                        .disabled(model.lfeMode == .off)
                    Spacer()
                }
                if model.lfeMode == .lowPass {
                    let cascade = BiquadDesign.butterworthLowPass(
                        frequency: Double(model.lfeCutoffText) ?? 120,
                        order: model.lfeOrder,
                        sampleRate: model.plotSampleRate)
                    let tau = cascade.groupDelay(at: 0, sampleRate: model.plotSampleRate)
                    Text(String(format: "Dry path delayed %.0f samples (%.2f ms) to match the filter.",
                                tau, tau / (model.plotSampleRate) * 1000))
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                }
            }

            CZCard(title: "True-peak limiter",
                   subtitle: "Catches inter-sample peaks with 4× oversampled detection and a look-ahead window, so the matrix can run at a useful level instead of being trimmed into the floor.") {
                CZToggleRow(title: "Enable limiter",
                            subtitle: "Adds \(String(format: "%.0f", 2.0)) ms of latency.",
                            isOn: $model.limiterEnabled)
                HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                    CZField(label: "Ceiling", text: $model.limiterCeilingText, suffix: "dBTP", width: 140)
                    CZField(label: "Release", text: $model.limiterReleaseText, suffix: "ms", width: 140)
                    Spacer()
                }
                .disabled(!model.limiterEnabled)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
            Text(value).font(CZ.Typography.mono(16)).foregroundStyle(CZ.Color.darkBlue)
            if let note {
                Text(note).font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChannelMapStrip: View {
    @EnvironmentObject var model: AppModel
    let layout: LayoutPreset

    /// Below this a slot counts as silent, so an idle bed does not look busy.
    private let floorDB = -60.0

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(BedChannel.allCases, id: \.rawValue) { ch in
                    cell(ch)
                }
            }
            HStack(spacing: CZ.Spacing.sm) {
                Text(model.state.isRunning
                     ? "Live input level per bed slot."
                     : "Levels appear once the renderer is running.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                Spacer()
                if model.state.isRunning {
                    let live = BedChannel.allCases.filter {
                        layout.map[$0.rawValue] > 0 && model.snapshot.bedPeakDB[$0.rawValue] > floorDB
                    }
                    CZPill(text: "\(live.count) of \(layout.activeChannels.count) carrying signal",
                           tint: live.isEmpty ? CZ.Color.mediumGray : CZ.Color.blue)
                }
            }
        }
    }

    private func cell(_ ch: BedChannel) -> some View {
        let slot = layout.map[ch.rawValue]
        let mapped = slot > 0
        let db = model.snapshot.bedPeakDB[ch.rawValue]
        let live = model.state.isRunning && mapped && db > floorDB
        let fraction = live ? min(max((db - floorDB) / (0 - floorDB), 0), 1) : 0

        return VStack(spacing: 2) {
            Text(ch.shortName)
                .font(CZ.Typography.mono(10))
                .foregroundStyle(mapped ? CZ.Color.darkBlue : CZ.Color.lightGray)
                .lineLimit(1)
            Text(mapped ? "ch \(slot)" : "—")
                .font(CZ.Typography.mono(9))
                .foregroundStyle(mapped ? CZ.Color.blue : CZ.Color.mutedGray)

            // Live level for this slot.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(CZ.Color.mutedGray.opacity(mapped ? 0.45 : 0.2))
                    Capsule()
                        .fill(db > -1 ? CZ.Color.red : (db > -6 ? CZ.Color.orange : CZ.Color.blue))
                        .frame(width: max(fraction > 0 ? 3 : 0, geo.size.width * fraction))
                        .animation(CZ.Motion.instant, value: fraction)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 4)

            Text(live ? String(format: "%.0f", db) : " ")
                .font(CZ.Typography.mono(8))
                .foregroundStyle(CZ.Color.mediumGray)
                .frame(height: 9)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(mapped ? (live ? CZ.Color.lightestBlue : CZ.Color.paleBlue) : CZ.Color.lightestGray)
        .overlay(
            RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                .strokeBorder(live ? CZ.Color.blue.opacity(0.55) : Color.clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.tiny))
    }
}

private struct MatrixTable: View {
    let matrix: SoundMixMatrix
    let layout: LayoutPreset

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bed channel").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Spacer()
                Text("→ L").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray).frame(width: 84, alignment: .trailing)
                Text("→ R").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray).frame(width: 84, alignment: .trailing)
            }
            .padding(.vertical, CZ.Spacing.xs)
            Divider().overlay(CZ.Color.ghostGray)
            ForEach(BedChannel.allCases, id: \.rawValue) { ch in
                let mapped = layout.map[ch.rawValue] > 0
                let v = matrix[ch]
                HStack {
                    Text(ch.shortName)
                        .font(CZ.Typography.mono(11))
                        .frame(width: 38, alignment: .leading)
                    Text(ch.longName)
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                    Spacer()
                    cell(v.left)
                    cell(v.right)
                }
                .foregroundStyle(mapped ? CZ.Color.defaultText : CZ.Color.mutedGray)
                .opacity(mapped ? 1 : 0.5)
                .padding(.vertical, 3)
            }
        }
    }

    private func cell(_ gain: Double) -> some View {
        let db = SoundMixMatrix.dB(abs(gain))
        return Text(abs(gain) < 1e-9 ? "—" : String(format: "%@%.2f dB", gain < 0 ? "ø " : "", db))
            .font(CZ.Typography.mono(11))
            .foregroundStyle(abs(gain) < 1e-9 ? CZ.Color.mutedGray
                             : (db > 0 ? CZ.Color.orange : CZ.Color.darkBlue))
            .frame(width: 84, alignment: .trailing)
    }
}

// MARK: - Output EQ

struct OutputEQPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            ProfileLibraryCard()
            ResponseCard()

            CZCard(title: "User / global PEQ",
                   subtitle: "Applied to both channels before the left/right swap, exactly where the original app applies it.") {
                PEQEditor(text: $model.globalPEQText, profile: model.globalProfile)
                    .onChange(of: model.globalPEQText) { _, _ in
                        model.reloadPEQWarnings(); model.markProfileDirty()
                    }
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Apply & save", icon: "checkmark.circle",
                             variant: .primary, size: .small) { model.applyAndSavePEQ() }
                    CZButton(title: "Load text file…", icon: "square.and.arrow.down",
                             variant: .secondary, size: .small) { load(into: $model.globalPEQText) }
                    CZButton(title: "Export as APO…", icon: "square.and.arrow.up",
                             variant: .transparent, size: .small,
                             isEnabled: model.selectedProfile != nil) {
                        model.exportSelectedAsAPO(speakerCorrection: false)
                    }
                    CZButton(title: "Clear", variant: .transparent, size: .small) {
                        model.globalPEQText = ""
                        model.reloadPEQWarnings(); model.markProfileDirty(); model.applyLive()
                    }
                }
            }

            CZDisclosureCard(title: "Speaker correction",
                             subtitle: "Applied per physical speaker after the swap. A stereo file's `l` and `r` sections map to the left and right speaker, and follow the swap when it is on.",
                             summary: model.speakerSectionSummary,
                             collapsed: $model.speakerSectionCollapsed) {
                PEQEditor(text: $model.speakerPEQText, profile: model.speakerProfiles.left)
                    .onChange(of: model.speakerPEQText) { _, _ in
                        model.reloadPEQWarnings(); model.markProfileDirty()
                    }
                HStack(spacing: CZ.Spacing.sm) {
                    CZButton(title: "Apply & save", icon: "checkmark.circle",
                             variant: .primary, size: .small) { model.applyAndSavePEQ() }
                    CZButton(title: "Load text file…", icon: "square.and.arrow.down",
                             variant: .secondary, size: .small) { load(into: $model.speakerPEQText) }
                    CZButton(title: "Export as APO…", icon: "square.and.arrow.up",
                             variant: .transparent, size: .small,
                             isEnabled: model.selectedProfile != nil) {
                        model.exportSelectedAsAPO(speakerCorrection: true)
                    }
                    CZButton(title: "Clear", variant: .transparent, size: .small) {
                        model.speakerPEQText = ""
                        model.reloadPEQWarnings(); model.markProfileDirty(); model.applyLive()
                    }
                }
            }

            if !model.peqWarnings.isEmpty {
                CZCard(title: "Parser notes") {
                    ForEach(model.peqWarnings, id: \.self) { w in
                        Text("· \(w)").font(CZ.Typography.caption).foregroundStyle(CZ.Color.orange)
                    }
                }
            }
        }
    }

    private func load(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose a REW / Equalizer APO text file."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                binding.wrappedValue = text
                model.reloadPEQWarnings()
                model.markProfileDirty()
                model.applyLive()
            } catch {
                model.errorMessage = "\(url.lastPathComponent) could not be read."
            }
        }
    }
}

// MARK: Profile library

private struct ProfileLibraryCard: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        CZCard(title: "Profile library",
               subtitle: "One file per profile in a folder you can back up or share. A profile holds both the global PEQ and the speaker correction.") {
            HStack(alignment: .top, spacing: CZ.Spacing.lg) {
                list
                detail
            }
            toolbar
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                    Text("No profiles yet")
                        .font(CZ.Typography.bodySmall).foregroundStyle(CZ.Color.mediumGray)
                    Text("Create one from whatever is in the editors below, or import a file.")
                        .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CZ.Spacing.md)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.profiles) { profile in
                            ProfileRow(profile: profile,
                                       selected: profile.id == model.selectedProfileID) {
                                model.selectProfile(profile)
                            }
                        }
                    }
                    .padding(CZ.Spacing.xs)
                }
                .frame(height: 188)
            }
        }
        .frame(width: 290)
        .background(CZ.Color.lightestGray)
        .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
            .strokeBorder(CZ.Color.ghostGray, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            CZField(label: "Profile name", text: $model.profileNameDraft)
            CZField(label: "Notes", text: $model.profileNotesDraft)

            // The earphone curves belong to the profile, one per ear.
            VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                HStack {
                    Text("Earphone response")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                    Spacer()
                    if model.measurementLeft != nil && model.measurementRight != nil {
                        CZButton(title: "Swap L/R", icon: "arrow.left.arrow.right",
                                 variant: .transparent, size: .small) {
                            model.swapMeasurements()
                        }
                    }
                    if model.hasMeasurement {
                        CZButton(title: "Remove both", variant: .transparent, size: .small) {
                            model.clearAllMeasurements()
                        }
                    }
                }
                ForEach(EQProfile.Side.allCases) { side in
                    EarSlot(side: side)
                }
                if !model.hasMeasurement {
                    Text("A three-column file (frequency, left, right) fills both ears at once.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                }
            }

            HStack(spacing: CZ.Spacing.sm) {
                if model.profileDirty {
                    CZPill(text: "unsaved changes", tint: CZ.Color.orange)
                } else if model.selectedProfile != nil {
                    CZPill(text: "saved", tint: CZ.Color.mediumGray)
                }
                if let p = model.selectedProfile {
                    Text("Modified \(Self.stamp.string(from: p.modified))")
                        .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolbar: some View {
        HStack(spacing: CZ.Spacing.sm) {
            CZButton(title: "New", icon: "plus", variant: .secondary, size: .small) {
                model.newProfile()
            }
            CZButton(title: "Duplicate", icon: "plus.square.on.square",
                     variant: .secondary, size: .small,
                     isEnabled: model.selectedProfile != nil) { model.duplicateSelectedProfile() }
            CZButton(title: confirmingDelete ? "Confirm delete" : "Delete",
                     icon: "trash", variant: confirmingDelete ? .danger : .transparent, size: .small,
                     isEnabled: model.selectedProfile != nil) {
                if confirmingDelete { model.deleteSelectedProfile(); confirmingDelete = false }
                else { confirmingDelete = true }
            }
            Divider().frame(height: 18)
            CZButton(title: "Import…", icon: "square.and.arrow.down",
                     variant: .secondary, size: .small) { model.importProfiles() }
            CZButton(title: "Export…", icon: "square.and.arrow.up",
                     variant: .secondary, size: .small,
                     isEnabled: model.selectedProfile != nil) {
                if let p = model.selectedProfile { model.exportProfiles([p], suggestedName: p.name) }
            }
            CZButton(title: "Export all", variant: .transparent, size: .small,
                     isEnabled: !model.profiles.isEmpty) {
                model.exportProfiles(model.profiles, suggestedName: "SoundMix EQ profiles")
            }
            Spacer()
            CZButton(title: "Show folder", icon: "folder",
                     variant: .transparent, size: .small) { model.revealProfileFolder() }
        }
        .onChange(of: model.selectedProfileID) { _, _ in confirmingDelete = false }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

private struct EarSlot: View {
    @EnvironmentObject var model: AppModel
    let side: EQProfile.Side
    @State private var showingPEQDB = false

    var body: some View {
        let curve = model.measurement(side)
        HStack(spacing: CZ.Spacing.sm) {
            Text(side.short)
                .font(CZ.Typography.mono(11))
                .foregroundStyle(curve == nil ? CZ.Color.mutedGray : CZ.Color.darkBlue)
                .frame(width: 14, alignment: .leading)
            if let curve {
                CZPill(text: curve.name, tint: side == .left ? CZ.Color.purple : CZ.Color.pink)
                Text(String(format: "%.0f Hz – %.0f kHz · %d pts",
                            curve.range.low, curve.range.high / 1000, curve.points.count))
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                    .lineLimit(1)
                Spacer()
                if model.measurement(side == .left ? .right : .left) == nil {
                    CZButton(title: "Copy to \(side == .left ? "R" : "L")",
                             variant: .transparent, size: .small) {
                        model.mirrorMeasurement(from: side)
                    }
                    CZButton(title: "Move to \(side == .left ? "R" : "L")",
                             variant: .transparent, size: .small) {
                        model.moveMeasurement(from: side)
                    }
                }
                CZButton(title: "Replace…", variant: .transparent, size: .small) {
                    model.loadMeasurement(for: side)
                }
                CZButton(title: "Remove", variant: .transparent, size: .small) {
                    model.clearMeasurement(side)
                }
            } else {
                Text("no \(side.label.lowercased()) curve")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                Spacer()
                CZButton(title: "Upload…", icon: "waveform.path.ecg",
                         variant: .secondary, size: .small) {
                    model.loadMeasurement(for: side)
                }
                CZButton(title: "From PEQdB…", icon: "sparkles",
                         variant: .secondary, size: .small) {
                    showingPEQDB = true
                }
            }
        }
        .sheet(isPresented: $showingPEQDB) {
            PEQDBPickerSheet(side: side)
        }
    }
}

/// Brand → model → variant picker over the PEQdB measurement database. Picks
/// fill the ear the sheet was opened for; a two-channel (matched L/R) entry
/// fills both, exactly like a three-column measurement file.
private struct PEQDBPickerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let side: EQProfile.Side

    @State private var query = ""
    @State private var selectedModel: PEQDBCatalog.Model?
    @State private var selectedVariant: PEQDBCatalog.Variant?

    private var results: [PEQDBCatalog.Model] {
        let catalog = PEQDBCatalog.shared
        return model.peqdbBrands.isEmpty ? [] : catalog.searchModels(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose earphone from PEQdB")
                        .font(CZ.Typography.body(14, .semibold))
                    Text("Search measured models — Super Review, Timtuned, oratory1990 and more. A matched pair fills both ears.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                }
                Spacer()
                if let updated = model.peqdbLastUpdated {
                    Text("Updated \(Self.stamp.string(from: updated))")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                }
                if model.peqdbLoading {
                    ProgressView().controlSize(.small)
                }
                CZButton(title: "Refresh database", icon: "arrow.clockwise",
                         variant: .secondary, size: .small,
                         isEnabled: !model.peqdbLoading) { model.loadPEQDB(refresh: true) }
                CZButton(title: "Close", variant: .transparent, size: .small) { dismiss() }
            }
            .padding(CZ.Spacing.md)

            if let error = model.peqdbError, model.peqdbBrands.isEmpty {
                VStack(spacing: CZ.Spacing.sm) {
                    Text(error)
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.orange)
                        .multilineTextAlignment(.center)
                    CZButton(title: "Retry", icon: "arrow.clockwise",
                             variant: .secondary, size: .small) { model.loadPEQDB(refresh: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search — type a model name, e.g. “Moondrop Chu”", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, CZ.Spacing.md)
                    .padding(.bottom, CZ.Spacing.xs)

                List(results, id: \.id) { candidate in
                    Button {
                        selectedModel = candidate
                        selectedVariant = candidate.variants.first
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.name)
                                    .font(CZ.Typography.body(13,
                                        candidate.id == selectedModel?.id ? .semibold : .regular))
                                Text("\(candidate.source) · \(candidate.variants.count) variant\(candidate.variants.count == 1 ? "" : "s")")
                                    .font(CZ.Typography.caption)
                                    .foregroundStyle(CZ.Color.lightGray)
                            }
                            Spacer()
                            if candidate.id == selectedModel?.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(CZ.Color.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)

                if let m = selectedModel {
                    HStack(spacing: CZ.Spacing.sm) {
                        if m.variants.count > 1 {
                            Picker("Variant", selection: Binding(
                                get: { selectedVariant ?? m.variants[0] },
                                set: { selectedVariant = $0 })) {
                                ForEach(m.variants) { v in
                                    Text(v.name).tag(v)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        } else if let v = m.variants.first {
                            Text(v.name).font(CZ.Typography.caption)
                                .foregroundStyle(CZ.Color.lightGray)
                        }
                        Spacer()
                        CZButton(title: "Load \(m.variants.count > 1 && (selectedVariant?.channelCount ?? 1) >= 2 ? "as L/R pair" : "into \(side.label.lowercased())")",
                                 icon: "waveform.path.ecg", variant: .primary, size: .small) {
                            if let v = selectedVariant {
                                model.applyPEQDBModel(m, variant: v, into: side)
                                dismiss()
                            }
                        }
                    }
                    .padding(CZ.Spacing.md)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { model.loadPEQDB() }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct ProfileRow: View {
    let profile: EQProfile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(CZ.Typography.body(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? CZ.Color.invertedText : CZ.Color.defaultText)
                    .lineLimit(1)
                Text(profile.summary)
                    .font(CZ.Typography.caption)
                    .foregroundStyle(selected ? CZ.Color.lightBlue : CZ.Color.lightGray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CZ.Spacing.sm + 2)
            .padding(.vertical, 7)
            .background(selected ? CZ.Color.darkBlue
                                 : (hovering ? CZ.Color.paleBlue : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.tiny + 2))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CZ.Motion.quick, value: hovering)
    }
}

/// The reference curve picker above the plot: None, the bundled reference
/// models, and a custom file, all writing to `model.target` directly.
private struct TargetPicker: View {
    @EnvironmentObject var model: AppModel

    private enum Tag: Hashable {
        case none, customFile, custom
        case builtIn(BuiltInTarget)
    }

    private var selection: Binding<Tag> {
        Binding(
            get: {
                guard let t = model.target else { return .none }
                // Bundled CSVs are parsed with the target's display name, so a
                // loaded built-in curve is recognised by name.
                if let builtIn = BuiltInTarget.all.first(where: { $0.name == t.name }) {
                    return .builtIn(builtIn)
                }
                return .custom
            },
            set: { tag in
                switch tag {
                case .none: model.clearTarget()
                case .customFile: model.loadTarget()
                case .custom: break
                case .builtIn(let target): model.loadBuiltInTarget(target)
                }
            })
    }

    var body: some View {
        HStack(spacing: CZ.Spacing.xs) {
            Text("Target:")
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.mediumGray)
            Picker("Target", selection: selection) {
                Text("None").tag(Tag.none)
                ForEach(BuiltInTarget.all) { target in
                    Text(target.name).tag(Tag.builtIn(target))
                }
                if selection.wrappedValue == .custom {
                    Text(model.target?.name ?? "Custom").tag(Tag.custom)
                }
                Divider()
                Text("Custom File…").tag(Tag.customFile)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 260)
            if let t = model.target {
                Text(String(format: "%.0f Hz – %.0f kHz", t.range.low, t.range.high / 1000))
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
            }
        }
    }
}

private struct ResponseCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let rate = model.plotSampleRate
        let boost = model.editorPeakBoostDB
        CZCard(title: "Response",
               subtitle: !model.hasMeasurement
                   ? "What the current profile does across the band, before it reaches the limiter. Load an earphone measurement to see the correction against the curve it is correcting."
                   : "The measured curve, the EQ applied to it, and the result you will actually hear.") {

            HStack {
                TargetPicker()
                Spacer()
                CZButton(title: "Expand & edit PEQ", icon: "arrow.up.left.and.arrow.down.right",
                         variant: .secondary, size: .small) {
                    PEQPlotWindow.shared.show(model: model)
                }
            }
            Text("Normalized response / EQ gain (dB)")
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.mediumGray)
            ResponseCurve(traces: ResponsePlotTraces.make(model: model, rate: rate,
                          global: model.globalProfile, speakers: model.speakerProfiles, target: model.target),
                          hidden: $model.hiddenTraces)

            if let error = model.measurementError {
                CZAlert(kind: .error, message: error)
            }
            if model.target != nil && !model.hasMeasurement {
                CZAlert(kind: .info,
                        message: "This profile has a target but no earphone measurement, so there is nothing to compare against — the plot can only show the filters themselves. Upload a measured curve above, or select the profile your measurements are on.")
            }

            HStack(spacing: CZ.Spacing.sm) {
                ForEach(EQProfile.Side.allCases) { side in
                    if let m = model.measurement(side) {
                        CZPill(text: "\(side.short) \(m.name)",
                               tint: side == .left ? CZ.Color.purple : CZ.Color.pink)
                    } else {
                        CZButton(title: "Upload \(side.short)…", icon: "waveform.path.ecg",
                                 variant: .secondary, size: .small) {
                            model.loadMeasurement(for: side)
                        }
                    }
                }
                if model.hasMeasurement {
                    CZButton(title: "Remove", variant: .transparent, size: .small) {
                        model.clearAllMeasurements()
                    }
                }
                Spacer()
                Text("Managed per profile, in the library above.")
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
            }

            Divider().overlay(CZ.Color.ghostGray)

            HStack(alignment: .center, spacing: CZ.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Peak boost").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                    Text(boost > -100 ? String(format: "%+.1f dB", boost) : "—")
                        .font(CZ.Typography.mono(14))
                        .foregroundStyle(boost > 0 ? CZ.Color.orange : CZ.Color.darkBlue)
                }
                if model.hasMeasurement {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Max absolute deviation").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                        Text(model.resultDeviationDB().map { String(format: "%.1f dB", $0) } ?? "—")
                            .font(CZ.Typography.mono(14))
                            .foregroundStyle(CZ.Color.darkBlue)
                    }
                    Text(model.target == nil
                         ? "Worst departure from the mean within measured coverage (20 Hz–20 kHz). Lower is flatter."
                         : "Worst departure within measurement/target overlap (20 Hz–20 kHz), across available ears. No overlap: —.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                        .fixedSize(horizontal: false, vertical: true)
                } else if boost > 0 {
                    Text("This profile adds gain, so it eats into the headroom the matrix trim left you. The limiter will catch it.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                CZToggleRow(title: "Bypass EQ", subtitle: "A/B against no correction.",
                            isOn: $model.eqBypassed)
                    .frame(width: 230)
                    .onChange(of: model.eqBypassed) { _, _ in model.applyLive() }
            }
        }
    }

}

private struct PEQEditor: View {
    @Binding var text: String
    let profile: PEQProfile

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            TextEditor(text: $text)
                .font(CZ.Typography.mono(11))
                .scrollContentBackground(.hidden)
                .padding(CZ.Spacing.sm)
                .frame(height: 120)
                .background(CZ.Color.lightestGray)
                .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
                    .strokeBorder(CZ.Color.mutedGray, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
            HStack(spacing: CZ.Spacing.sm) {
                CZPill(text: "\(profile.activeFilterCount) active filters", tint: CZ.Color.blue)
                CZPill(text: String(format: "preamp %+.1f dB", profile.preampDB), tint: CZ.Color.mediumGray)
                Spacer()
                Text("REW / Equalizer APO format")
                    .font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
            }
        }
    }
}

// MARK: - Monitor

struct MonitorPanel: View {
    @EnvironmentObject var model: AppModel

    private let topRow: [BedChannel] = [.ltf, .rtf, .ltm, .rtm, .ltr, .rtr]
    private let bedRow: [BedChannel] = [.l, .r, .c, .lfe, .lw, .rw, .ls, .rs, .lrs, .rrs]

    var body: some View {
        VStack(spacing: CZ.Spacing.md) {
            CZCard(title: "Output") {
                CZMeterBar(label: "L", db: model.snapshot.outputPeakDB.0,
                           rmsDB: model.snapshot.outputRMSDB.0, clipped: model.snapshot.clipLeft > 0)
                CZMeterBar(label: "R", db: model.snapshot.outputPeakDB.1,
                           rmsDB: model.snapshot.outputRMSDB.1, clipped: model.snapshot.clipRight > 0)
                HStack(spacing: CZ.Spacing.lg) {
                    stat("Stereo limiter", model.limiterStatus)
                    stat("Clips", "\(model.snapshot.clipLeft + model.snapshot.clipRight)")
                    stat("Buffer underruns", "\(model.snapshot.underruns)")
                    stat("Chain latency", String(format: "%.1f ms", model.snapshot.latencyMS))
                    Spacer()
                }
            }

            CZCard(title: "Height layer") {
                HStack(spacing: CZ.Spacing.sm) { cells(topRow) }
            }

            CZCard(title: "Bed layer") {
                HStack(spacing: CZ.Spacing.sm) { cells(bedRow) }
            }
        }
    }

    private func cells(_ channels: [BedChannel]) -> some View {
        ForEach(channels, id: \.rawValue) { ch in
            CZChannelCell(name: ch.shortName,
                          db: model.snapshot.bedPeakDB[ch.rawValue],
                          active: model.layout.map[ch.rawValue] > 0)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
            Text(value).font(CZ.Typography.mono(13)).foregroundStyle(CZ.Color.darkBlue)
        }
    }
}

// MARK: - Log

struct LogPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        CZCard {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(CZ.Typography.mono(11))
                                .foregroundStyle(CZ.Color.mediumGray)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 420)
                .onChange(of: model.log.count) { _, count in
                    if let last = model.log.last {
                        withAnimation(CZ.Motion.quick) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            HStack {
                Spacer()
                CZButton(title: "Clear", variant: .transparent, size: .small) { model.clearLog() }
            }
        }
    }
}
