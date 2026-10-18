import SwiftUI

/// Announces an available SoundMix release at the top of the content area,
/// with a hop out to the GitHub release page and a per-version skip.
/// Renders nothing while the checker has no banner to show.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let banner = checker.banner {
            HStack(alignment: .top, spacing: CZ.Spacing.sm) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(CZ.Color.blue)
                VStack(alignment: .leading, spacing: CZ.Spacing.xs) {
                    Text("SoundMix \(banner.newVersion.displayString) is available.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.defaultText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The release page opens in your browser; download the DMG and drag it to Applications.")
                        .font(CZ.Typography.caption)
                        .foregroundStyle(CZ.Color.mediumGray)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: CZ.Spacing.sm) {
                        CZButton(title: "Get Update") { checker.getUpdate() }
                        CZButton(title: "Skip This Version", variant: .secondary) { checker.skip() }
                    }
                    .padding(.top, CZ.Spacing.xs)
                }
                Spacer(minLength: CZ.Spacing.sm)
                Button {
                    checker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CZ.Color.mediumGray)
                        .padding(CZ.Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(CZ.Spacing.lg)
            .background(CZ.Color.blue.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: CZ.Radius.medium))
        }
    }
}
