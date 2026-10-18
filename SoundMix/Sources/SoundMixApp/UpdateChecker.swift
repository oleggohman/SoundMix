import AppKit
import Combine
import Foundation

// App layer of the update check. SoundMixCore's UpdateCheck.swift owns the
// pure logic (tag parsing, version comparison, schedule math, skip list);
// this file owns the network call and the UI state published off it.

/// Checks GitHub for a newer SoundMix release and publishes what the update
/// banner should show.
///
/// The main actor is never blocked: the request runs on a utility queue and
/// only the decision hops back to the main thread. Noise rules, per plan:
/// - an automatic check runs at most once per 24 hours (`UpdateSchedule`) and
///   stays silent unless a newer, unskipped release exists;
/// - a skipped version never re-nags;
/// - GitHub's unauthenticated budget (60 req/h/IP) buys exactly one request
///   per attempt — 403/429 surface as a failure, never as a retry loop.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Everything the banner needs to draw itself: the release it points at
    /// and the version that made it worth showing.
    struct BannerState {
        /// The GitHub release behind the offer (page URL, DMG link, notes).
        let info: ReleaseInfo

        /// The release's version, parsed once so no view touches raw tags.
        let newVersion: Version
    }

    /// Non-nil while a newer, not-yet-skipped release is on offer.
    @Published private(set) var banner: BannerState?

    /// The running build. Nil only where there is no Info.plist to read (a
    /// bare CLI launched from a checkout); nothing can be "newer" then, so
    /// no update is ever offered.
    private let currentVersion: Version?

    /// One check at a time: a call made while a request is still in flight
    /// is ignored, not queued.
    private var isChecking = false

    /// Versions the user asked not to hear about again.
    private var skipState = SkipState()

    /// The 24-hour cadence, consulted for automatic checks only.
    private let schedule = UpdateSchedule()

    /// The store both halves of the cadence share: `updateCheck.lastCheck`
    /// here, `SkipState`'s own keys inside it.
    private let defaults = UserDefaults.standard

    /// Defaults key holding the date of the last completed attempt.
    private static let lastCheckKey = "updateCheck.lastCheck"

    /// The latest-release endpoint. Must match the repo `build-dmg.sh`
    /// publishes to (`--repo oleggohman/SoundMix`).
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/oleggohman/SoundMix/releases/latest")!

    /// How long a request may hang before it is written off.
    private static let requestTimeout: TimeInterval = 15

    /// No cookies and no on-disk cache: a stale cached `/releases/latest`
    /// would let a manual re-check lie about what GitHub currently says.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdateChecker.requestTimeout
        return URLSession(configuration: configuration)
    }()

    /// Alert copy for manual-check results, verbatim from the plan.
    private enum Copy {
        /// Title when the running build is the newest there is.
        static let upToDateTitle = "SoundMix is up to date"

        /// Title when a newer release exists.
        static let availableTitle = "Update available"

        /// Title when the check could not complete.
        static let failedTitle = "Could not check for updates"

        /// Body for the failure case; rate limits (403/429) land here too.
        static let failedMessage = "GitHub didn't respond (offline or rate-limited). Try again later."

        /// Body for the up-to-date case; `version` is the running build.
        static func upToDateMessage(running version: String) -> String {
            "You're running \(version) — the latest release."
        }

        /// Body for the available case; `version` is the new release.
        static func availableMessage(version: String) -> String {
            "\(version) is available. See the release page for details."
        }
    }

    /// - Parameter currentVersion: the build releases are compared against;
    ///   defaults to the app bundle's own version.
    init(currentVersion: Version? = Bundle.main.version) {
        self.currentVersion = currentVersion
    }

    /// Asks GitHub for the latest release and shows the banner if it is
    /// newer than the running build.
    ///
    /// Automatic checks (`manual: false`) consult the 24-hour schedule
    /// first and silently do nothing when not due. Manual checks always run
    /// and answer with an alert — up to date, available, or failed — while
    /// automatic ones stay quiet no matter the outcome. Every completed
    /// attempt, successful or not, stamps `updateCheck.lastCheck`; that is
    /// what keeps a flaky network from turning the daily cadence into a
    /// rate-limit burn.
    func checkForUpdates(manual: Bool) {
        guard !isChecking else { return }
        guard let current = currentVersion else {
            // No bundle version means no baseline to compare against — the
            // automatic check stays silent, but a manual one still owes the
            // user an answer rather than a dead menu item.
            if manual {
                presentAlert(title: Copy.failedTitle, message: Copy.failedMessage)
            }
            return
        }

        if !manual {
            let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
            guard schedule.shouldCheck(now: Date(), lastCheck: lastCheck) else { return }
        }
        isChecking = true

        var request = URLRequest(url: Self.latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        // Networking stays off the main actor; the decision comes back below.
        let session = Self.session
        DispatchQueue.global(qos: .utility).async {
            session.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async { [weak self] in
                    self?.finishCheck(data: data,
                                      response: response,
                                      error: error,
                                      manual: manual,
                                      current: current)
                }
            }.resume()
        }
    }

    /// Opens the release page in the default browser. Phase 1 keeps the
    /// install manual: the page carries the DMG, nothing is downloaded
    /// in-app (no Sparkle — the app is ad-hoc signed). The banner stays up
    /// so the link is still reachable after returning from the browser.
    func getUpdate() {
        guard let banner else { return }
        NSWorkspace.shared.open(banner.info.pageURL)
    }

    /// Hides the banner for this session; the next due check may bring it
    /// back.
    func dismiss() {
        banner = nil
    }

    /// Hides the banner and records the version as skipped, so neither this
    /// session nor a later one nags about it again.
    func skip() {
        guard let currentBanner = banner else { return }
        skipState.skip(tag: currentBanner.info.version.tagString)
        banner = nil
    }

    /// Turns a completed request into UI state. Reached through the hop to
    /// main above; `current` is the running build the request was made for.
    private func finishCheck(data: Data?,
                             response: URLResponse?,
                             error: Error?,
                             manual: Bool,
                             current: Version) {
        isChecking = false

        // Every completed attempt — success, HTTP error, rate limit, network
        // failure — moves the schedule forward.
        defaults.set(Date(), forKey: Self.lastCheckKey)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || status != 200 {
            // 403/429 land here: reported once, never retried in a loop.
            if manual {
                presentAlert(title: Copy.failedTitle, message: Copy.failedMessage)
            }
            return
        }

        guard let data = data,
              let info = ReleaseInfo.parse(from: data),
              info.version > current else {
            // No newer build to act on. A release that fails to parse counts
            // as "no news", not as an error — the next scheduled check
            // retries on its own.
            if manual {
                presentAlert(title: Copy.upToDateTitle,
                             message: Copy.upToDateMessage(running: current.displayString))
            }
            return
        }

        if skipState.isSkipped(tag: info.version.tagString) {
            // The user asked not to be nagged about this version, so the
            // banner stays down; a manual check still answers honestly.
            if manual {
                presentAlert(title: Copy.availableTitle,
                             message: Copy.availableMessage(version: info.version.displayString))
            }
            return
        }

        banner = BannerState(info: info, newVersion: info.version)
        if manual {
            presentAlert(title: Copy.availableTitle,
                         message: Copy.availableMessage(version: info.version.displayString))
        }
    }

    /// Shows one of the fixed manual-result alerts modally. There is no
    /// window reference to hang a sheet on from here, so a plain app-modal
    /// NSAlert does the job.
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// The running build's version, assembled to match the release tags:
/// `v` + short version + `-build-` + bundle number. Nil when either key is
/// missing — a bare CLI without an Info.plist has no version to compare.
fileprivate extension Bundle {
    /// `Version.parse` over `v<CFBundleShortVersionString>-build-<CFBundleVersion>`.
    var version: Version? {
        guard let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { return nil }
        return Version.parse("v\(short)-build-\(build)")
    }
}
