import SwiftUI

// All components are custom-built on SwiftUI primitives — no third-party UI kit.

// MARK: - Card

struct CZCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var padding: CGFloat = CZ.Spacing.xl
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.md) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                    if let title {
                        Text(title)
                            .font(CZ.Typography.title)
                            .foregroundStyle(CZ.Color.defaultText)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(CZ.Typography.caption)
                            .foregroundStyle(CZ.Color.mediumGray)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CZ.Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: CZ.Radius.large)
                .strokeBorder(CZ.Color.ghostGray, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.large))
    }
}

// MARK: - Collapsible card

/// A card that folds away, with a one-line summary of what it holds while
/// closed. The original app made every section collapsible; this keeps that,
/// but remembers the state per section.
struct CZDisclosureCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Shown on the right of the header while collapsed.
    var summary: String? = nil
    @Binding var collapsed: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(CZ.Motion.normal) { collapsed.toggle() }
            } label: {
                HStack(alignment: .center, spacing: CZ.Spacing.md) {
                    Text(title)
                        .font(CZ.Typography.title)
                        .foregroundStyle(CZ.Color.defaultText)
                    Spacer(minLength: CZ.Spacing.sm)
                    if let summary, collapsed {
                        Text(summary)
                            .font(CZ.Typography.caption)
                            .foregroundStyle(CZ.Color.mediumGray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CZ.Color.mediumGray)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                if let subtitle {
                    Text(subtitle)
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, CZ.Spacing.xs)
                }
                VStack(alignment: .leading, spacing: CZ.Spacing.md) {
                    content
                }
                .padding(.top, CZ.Spacing.md)
            }
        }
        .padding(CZ.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CZ.Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: CZ.Radius.large)
                .strokeBorder(CZ.Color.ghostGray, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.large))
    }
}

// MARK: - Button

enum CZButtonVariant { case primary, secondary, transparent, danger }
enum CZButtonSize {
    case small, normal, large
    var minHeight: CGFloat { self == .small ? 24 : (self == .normal ? 38 : 50) }
    var radius: CGFloat { self == .small ? CZ.Radius.medium : (self == .normal ? CZ.Radius.pill : 48) }
    var font: CGFloat { self == .small ? 12 : (self == .normal ? 14 : 16) }
    var hPadding: CGFloat { self == .small ? CZ.Spacing.md : CZ.Spacing.lg }
}

struct CZButton: View {
    let title: String
    var icon: String? = nil
    var variant: CZButtonVariant = .primary
    var size: CZButtonSize = .normal
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    private var background: Color {
        guard isEnabled else { return CZ.Color.mutedGray }
        switch variant {
        case .primary:   return hovering ? CZ.Color.purple : CZ.Color.blue
        case .secondary: return hovering ? CZ.Color.lightBlue : CZ.Color.paleBlue
        case .danger:    return hovering ? CZ.Color.red.opacity(0.85) : CZ.Color.red
        case .transparent: return .clear
        }
    }

    private var foreground: Color {
        guard isEnabled else { return CZ.Color.white.opacity(0.85) }
        switch variant {
        case .primary, .danger: return CZ.Color.white
        case .secondary:        return CZ.Color.darkBlue
        case .transparent:      return CZ.Color.darkBlue
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CZ.Spacing.sm) {
                if let icon { Image(systemName: icon).font(.system(size: size.font)) }
                Text(title)
                    .font(CZ.Typography.ui(size.font, .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size.hPadding)
            .frame(minHeight: size.minHeight)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: size.radius))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 && isEnabled }
        .animation(CZ.Motion.quick, value: hovering)
    }
}

// MARK: - Field & select

struct CZField: View {
    let label: String
    @Binding var text: String
    var suffix: String? = nil
    var help: String? = nil
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
            Text(label)
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.mediumGray)
            HStack(spacing: CZ.Spacing.xs) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(CZ.Typography.input)
                    .foregroundStyle(CZ.Color.defaultText)
                if let suffix {
                    Text(suffix)
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.lightGray)
                }
            }
            .padding(.horizontal, CZ.Spacing.md)
            .frame(height: 38)
            .background(CZ.Color.white)
            .overlay(RoundedRectangle(cornerRadius: CZ.Radius.medium)
                .strokeBorder(CZ.Color.mutedGray, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
            .frame(width: width)
            if let help {
                Text(help).font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
            }
        }
    }
}

struct CZSelect<T: Hashable>: View {
    let label: String
    @Binding var selection: T
    let options: [(value: T, title: String)]
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
            Text(label)
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.mediumGray)
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(CZ.Typography.input)
            .tint(CZ.Color.blue)
            if let help {
                Text(help)
                    .font(CZ.Typography.caption)
                    .foregroundStyle(CZ.Color.lightGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct CZToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CZ.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CZ.Typography.bodySmall).foregroundStyle(CZ.Color.defaultText)
                if let subtitle {
                    Text(subtitle).font(CZ.Typography.caption).foregroundStyle(CZ.Color.lightGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: CZ.Spacing.md)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(CZ.Color.blue)
        }
    }
}

// MARK: - Status pill & alert

struct CZPill: View {
    let text: String
    var tint: Color = CZ.Color.blue
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(CZ.Typography.ui(11, .semibold))
            .foregroundStyle(filled ? CZ.Color.white : tint)
            .padding(.horizontal, CZ.Spacing.sm + 2)
            .padding(.vertical, 4)
            .background(filled ? tint : tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

struct CZAlert: View {
    enum Kind { case error, warning, info
        var tint: Color {
            switch self {
            case .error: return CZ.Color.red
            case .warning: return CZ.Color.orange
            case .info: return CZ.Color.blue
            }
        }
        var icon: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }
    let kind: Kind
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: CZ.Spacing.sm) {
            Image(systemName: kind.icon).foregroundStyle(kind.tint)
            Text(message)
                .font(CZ.Typography.caption)
                .foregroundStyle(CZ.Color.defaultText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(CZ.Spacing.lg)
        .background(kind.tint.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
    }
}

// MARK: - Meters

/// Horizontal dBFS bar with a peak cap and a clip flag.
struct CZMeterBar: View {
    let label: String
    let db: Double
    let rmsDB: Double
    var clipped: Bool = false
    var floor: Double = -60

    private func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max((value - floor) / (0 - floor), 0), 1)
    }

    private var tint: Color {
        if clipped || db > -0.1 { return CZ.Color.red }
        if db > -3 { return CZ.Color.orange }
        return CZ.Color.blue
    }

    var body: some View {
        HStack(spacing: CZ.Spacing.sm) {
            Text(label)
                .font(CZ.Typography.mono(11))
                .foregroundStyle(CZ.Color.mediumGray)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                        .fill(CZ.Color.lightestGray)
                    RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                        .fill(CZ.Color.mediumBlue.opacity(0.55))
                        .frame(width: geo.size.width * fraction(rmsDB))
                    RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * fraction(db)))
                        .animation(CZ.Motion.instant, value: db)
                }
            }
            .frame(height: 10)
            Text(db.isFinite ? String(format: "%6.1f", db) : "  -inf")
                .font(CZ.Typography.mono(11))
                .foregroundStyle(clipped ? CZ.Color.red : CZ.Color.mediumGray)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// Compact vertical level cell used by the bed visualiser.
struct CZChannelCell: View {
    let name: String
    let db: Double
    let active: Bool
    var floor: Double = -60

    private var fraction: Double {
        guard db.isFinite else { return 0 }
        return min(max((db - floor) / (0 - floor), 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                    .fill(active ? CZ.Color.lightestBlue : CZ.Color.lightestGray)
                RoundedRectangle(cornerRadius: CZ.Radius.tiny)
                    .fill(db > -1 ? CZ.Color.red : (db > -6 ? CZ.Color.orange : CZ.Color.blue))
                    .frame(height: max(2, 44 * fraction))
            }
            .frame(height: 44)
            Text(name)
                .font(CZ.Typography.mono(9))
                .foregroundStyle(active ? CZ.Color.darkBlue : CZ.Color.lightGray)
                .lineLimit(1)
        }
        .opacity(active ? 1 : 0.4)
    }
}
