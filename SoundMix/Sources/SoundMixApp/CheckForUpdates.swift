import Combine
import Sparkle
import SwiftUI

// The app-side face of Sparkle. The updater itself (feed URL, EdDSA key,
// daily schedule) is configured in Info.plist; Sparkle's standard window
// shows the offer, the release notes, the download and the relaunch.

/// Mirrors the updater's `canCheckForUpdates` so SwiftUI can enable and
/// disable the menu item. Sparkle turns it off while a check or an install
/// is already in progress.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    /// True while the updater would accept a user-initiated check.
    @Published private(set) var canCheckForUpdates = false

    /// - Parameter updater: the app's one updater; its KVO-observable
    ///   property drives `canCheckForUpdates`.
    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The **Check for Updates…** menu item. Sparkle answers with its own
/// window: an offer, "up to date", or an error.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel

    /// The updater the item drives; owned by `SoundMixApp`.
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}
