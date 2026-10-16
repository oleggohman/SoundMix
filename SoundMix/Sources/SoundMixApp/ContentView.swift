import SwiftUI

enum Panel: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case downmix = "Downmix"
    case outputEQ = "Output EQ"
    case monitor = "Monitor"
    case log = "Log"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .devices:  return "waveform.and.magnifyingglass"
        case .downmix:  return "square.grid.3x3.topleft.filled"
        case .outputEQ: return "slider.horizontal.3"
        case .monitor:  return "chart.bar.fill"
        case .log:      return "text.alignleft"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var panel: Panel = .devices

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(panel: $panel)
                .frame(width: 272)
            contentArea
        }
        .background(CZ.Color.darkBlue)
        .frame(minWidth: 1024, minHeight: 680)
        .onDisappear { model.save() }
    }

    private var contentArea: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: CZ.Spacing.md) {
                    if let error = model.errorMessage {
                        CZAlert(kind: .error, message: error)
                    }
                    switch panel {
                    case .devices:  DevicesPanel()
                    case .downmix:  SoundMixPanel()
                    case .outputEQ: OutputEQPanel()
                    case .monitor:  MonitorPanel()
                    case .log:      LogPanel()
                    }
                }
                .padding(.horizontal, CZ.Spacing.xxl)
                .padding(.bottom, CZ.Spacing.xl)
            }
            TransportBar()
        }
        .background(CZ.Color.paleBlue)
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.pill))
        .padding(CZ.Spacing.sm)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                Text(panel.rawValue)
                    .font(CZ.Typography.largeTitle)
                    .foregroundStyle(CZ.Color.darkBlue)
                Text(subtitle)
                    .font(CZ.Typography.bodySmall)
                    .foregroundStyle(CZ.Color.mediumGray)
            }
            Spacer()
            StatusBadge()
        }
        .padding(.horizontal, CZ.Spacing.xxl)
        .padding(.top, CZ.Spacing.xl)
        .padding(.bottom, CZ.Spacing.lg)
    }

    private var subtitle: String {
        switch panel {
        case .devices:  return "Pick the interface carrying the bed and the pair of speakers it folds down to."
        case .downmix:  return "Choose how the bed collapses to two channels, and how much headroom that costs."
        case .outputEQ: return "Parametric correction, in the same REW / Equalizer APO format you already use."
        case .monitor:  return "Per-channel bed activity, output level, and what the limiter is doing."
        case .log:      return "What the engine did, in order."
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var panel: Panel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                HStack(spacing: CZ.Spacing.sm) {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(CZ.Color.blue)
                    Text("SoundMix")
                        .font(CZ.Typography.body(19, .semibold, display: true))
                        .foregroundStyle(CZ.Color.invertedText)
                }

            }
            .padding(.horizontal, CZ.Spacing.lg)
            .padding(.top, CZ.Spacing.xl)
            .padding(.bottom, CZ.Spacing.xl)

            VStack(spacing: 2) {
                ForEach(Panel.allCases) { item in
                    NavItem(item: item, selected: panel == item) { panel = item }
                }
            }
            .padding(.horizontal, CZ.Spacing.sm + 4)

            Spacer()
            SidebarSummary()
                .padding(.horizontal, CZ.Spacing.lg)
                .padding(.bottom, CZ.Spacing.lg)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CZ.Color.darkBlue)
    }
}

private struct NavItem: View {
    let item: Panel
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: CZ.Spacing.sm + 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(CZ.Typography.ui(14, selected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(selected ? CZ.Color.invertedText : CZ.Color.mediumBlue)
            .padding(.horizontal, CZ.Spacing.md)
            .frame(height: 40)
            .background(selected ? CZ.Color.blue.opacity(0.22)
                                 : (hovering ? CZ.Color.white.opacity(0.06) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(CZ.Motion.quick, value: hovering)
    }
}

private struct SidebarSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.sm) {
            row("Layout", model.layout.name)
            row("Matrix", short(model.recipeName))
            row("EQ", eqLabel)
            row("Trim", String(format: "%+.1f dB", model.configuration.totalTrimDB))
            row("Worst case", String(format: "%+.1f dB", model.configuration.effectiveMatrix.worstCasePeakGainDB))
            if model.state.isRunning {
                row("Latency", String(format: "%.1f ms", model.snapshot.latencyMS))
                row("Rate", "\(Int(model.engine.currentSampleRate)) Hz")
            }
            Divider().overlay(CZ.Color.mediumBlue.opacity(0.3))
            row("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            row("Build", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
        }
        .padding(CZ.Spacing.md)
        .background(CZ.Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
    }

    /// The EQ profile in force, so it is visible without opening the panel.
    private var eqLabel: String {
        if model.eqBypassed { return "bypassed" }
        guard let p = model.selectedProfile else {
            let hasText = !model.globalPEQText.isEmpty || !model.speakerPEQText.isEmpty
            return hasText ? "unsaved" : "none"
        }
        return model.profileDirty ? "\(p.name) •" : p.name
    }

    private func short(_ s: String) -> String {
        guard let paren = s.firstIndex(of: "(") else { return s }
        return String(s[s.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumBlue)
            Spacer()
            Text(value)
                .font(CZ.Typography.mono(11))
                .foregroundStyle(CZ.Color.invertedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Status + transport

struct StatusBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.state {
        case .stopped:  CZPill(text: "Idle", tint: CZ.Color.mediumGray)
        case .starting: CZPill(text: "Starting", tint: CZ.Color.orange, filled: true)
        case .running:  CZPill(text: "Rendering", tint: CZ.Color.blue, filled: true)
        case .failed:   CZPill(text: "Stopped", tint: CZ.Color.red, filled: true)
        }
    }
}

struct TransportBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(CZ.Color.ghostGray)
            HStack(spacing: CZ.Spacing.md) {
                if model.state.isRunning, let restart = model.restartReason {
                    HStack(spacing: CZ.Spacing.xs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(CZ.Color.orange)
                        Text(restart)
                            .font(CZ.Typography.caption)
                            .foregroundStyle(CZ.Color.mediumGray)
                    }
                } else if model.state.isRunning {
                    MiniMeters()
                } else if let reason = model.startBlockedReason {
                    HStack(spacing: CZ.Spacing.xs) {
                        Image(systemName: "info.circle").foregroundStyle(CZ.Color.lightGray)
                        Text(reason).font(CZ.Typography.caption).foregroundStyle(CZ.Color.mediumGray)
                    }
                } else {
                    Text("Ready to render \(model.layout.name) → stereo.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                }
                Spacer()
                if model.state.isRunning {
                    // One Apply everywhere: the same thing the Output EQ card's
                    // Apply & save does — the engine gets the settings and the
                    // selected profile is persisted. A bar that only pushed to
                    // the engine silently dropped the EQ profile.
                    CZButton(title: model.needsRestartToApply ? "Apply & restart" : "Apply",
                             icon: "arrow.triangle.2.circlepath",
                             variant: .secondary) { model.applyAndSavePEQ() }
                    CZButton(title: "Stop", icon: "stop.fill", variant: .danger) { model.stop() }
                } else {
                    CZButton(title: "Start", icon: "play.fill", variant: .primary,
                             isEnabled: model.startBlockedReason == nil) { model.start() }
                }
            }
            .padding(.horizontal, CZ.Spacing.xxl)
            .padding(.vertical, CZ.Spacing.md)
        }
        .background(CZ.Color.white)
    }
}

private struct MiniMeters: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: CZ.Spacing.lg) {
            VStack(spacing: 3) {
                CZMeterBar(label: "L", db: model.snapshot.outputPeakDB.0,
                           rmsDB: model.snapshot.outputRMSDB.0,
                           clipped: model.snapshot.clipLeft > 0)
                CZMeterBar(label: "R", db: model.snapshot.outputPeakDB.1,
                           rmsDB: model.snapshot.outputRMSDB.1,
                           clipped: model.snapshot.clipRight > 0)
            }
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 2) {
                Text("Stereo limiter").font(CZ.Typography.label).foregroundStyle(CZ.Color.mediumGray)
                Text(model.limiterStatus)
                    .font(CZ.Typography.mono(13))
                    .foregroundStyle(model.snapshot.gainReductionDB > 0.05 ? CZ.Color.orange : CZ.Color.lightGray)
            }
            .frame(width: 112, alignment: .leading)
            .help("One linked limiter protects both outputs. Ready means no gain reduction; it does not raise quiet audio.")
        }
    }
}
