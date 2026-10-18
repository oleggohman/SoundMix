# GitHub Releases Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SoundMix checks GitHub Releases on launch (24 h cache, silent on failure) and via a "Check for Updates…" menu item, and shows an in-app banner when a newer build exists.

**Architecture:** One pure-logic Swift file in SoundMixCore (`UpdateCheck.swift`): tag parsing/comparison, a `ReleaseInfo` payload from the GitHub API, and a scheduler gate with UserDefaults-backed skip state. Networking lives in SoundMixApp (`UpdateChecker.swift`): a `@MainActor ObservableObject` that fetches, decides, and publishes UI state; UI is a menu item plus a banner view. Pure logic is verified in `Tests/main.swift` (which compiles only SoundMixCore); the app layer has no unit tests, by repo convention.

**Tech Stack:** Swift 5, Foundation (URLSession, UserDefaults), SwiftUI/AppKit. No Sparkle, no new dependencies, no Package.swift (repo builds via `swiftc` shell scripts).

**Spec:** `PLAN.md` (repo root, git-ignored local plan document; "Update mechanism GitHub Releases" section). Discrepancies resolved against the live repo on 2026-10-18: canonical repo slug is `oleggohman/SoundMix` (the `--repo oleggohman/SoundAPP` in `build-dmg.sh` is stale — GitHub redirects, but Task 1 pins release publishing to the canonical name).

## Global Constraints

- Repo: `oleggohman/SoundMix`; latest release today: `v1.2.0-build-58`, asset `SoundMix-1.2.0-build-58.dmg`.
- Tag format: `v<major>.<minor>.<patch>-build-<n>` (e.g. `v1.2.0-build-58`). DMG asset names: `SoundMix-<major>.<minor>.<patch>-build-<n>.dmg` (no leading `v`).
- Comparison is numeric: version tuple first, then build number (`1.2.0-build-58` > `1.2.0-build-9`; `1.3.0-build-1` > `1.2.9-build-99`).
- Launch check runs at most once per 24 hours (timing persisted in UserDefaults), is silent on any failure, and never blocks or delays UI.
- No background polling — one gated check per launch plus the manual menu item.
- Unauthenticated GitHub API: 60 req/h/IP; treat `403`/`429` as "no update" and stamp the schedule clock anyway (a rate-limited launch must not retry-loop).
- Skip-this-version stored in UserDefaults; a skipped tag never re-shows the banner (manual check still reports it).
- Phase 1 UX: the banner's "Get Update" opens the release page in the default browser; no in-app download.
- Sparkle stays out (app is ad-hoc signed, not notarized).
- Network on a background queue (`DispatchQueue.global(qos: .utility)`); UI updates on main.
- Builds/tests: `SoundMix/build.sh` and `SoundMix/run-tests.sh` glob `Sources/SoundMixCore/*.swift` flat — the new core file must sit flat in that directory, not a subfolder.
- Test harness style: `section("…")` / `check(...)` / `near(...)` in `Tests/main.swift`, no XCTest.
- Code style: doc comments on every declaration, present tense, matching the tone of `Telemetry.swift`.
- macOS 14+ (`LSMinimumSystemVersion` 14.0).
- Commit messages end with `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

## Review Focus

Inputs and failure modes the spec implies but no happy-path test exercises — each pinned by a test in the owning task:

1. **Tags that don't parse** (draft/moved `latest` release, or a tag like `v1.3.0` with no `-build-`) → must read as "no update", never a crash or false positive. Test: Task 2, `ReleaseInfo` section.
2. **Numeric build comparison** (`build-58` vs `build-9` string-compare bug class) → 58 > 9 must hold. Test: Task 2, `Version` section.
3. **403/429 rate-limit responses** → silent no-op, no error surface, and the 24 h clock still advances. Test: Task 2 (gate is pure) + Task 3 (checker stamps `lastCheck` on failure).
4. **Skipped version resurfacing** — same tag found on next launch → banner suppressed; a newer tag bypasses the skip. Test: Task 2, `SkipState` section.
5. **Running a build newer than the latest release** (dev build `v1.2.0-build-61` vs released `build-58`) → must read as up-to-date, not "update available". Test: Task 2, `Version` ordering.

(Also handled, without a unit test because it is app-layer: no-Info.plist environments — the CLI test binary. `Bundle.main.version` returns nil and the checker treats a nil current version as "cannot compare, stay silent". Documented in Task 3.)

## File Structure

- Create: `SoundMix/Sources/SoundMixCore/UpdateCheck.swift` — `Version` (tuple parse/compare), `ReleaseInfo` (GitHub JSON), `UpdateSchedule` (24 h gate), `SkipState` (skip list, injectable store).
- Create: `SoundMix/Sources/SoundMixApp/UpdateChecker.swift` — `UpdateChecker: ObservableObject` (networking + published UI state + manual-result alert).
- Create: `SoundMix/Sources/SoundMixApp/UpdateBanner.swift` — banner view.
- Modify: `SoundMix/Sources/SoundMixApp/main.swift` — menu item, launch check, environment object.
- Modify: `SoundMix/Sources/SoundMixApp/ContentView.swift` — render `UpdateBanner` above the `model.errorMessage` slot.
- Modify: `SoundMix/Tests/main.swift` — new sections for the core logic.
- Modify: `SoundMix/build-dmg.sh:78` — `--repo oleggohman/SoundMix`.

**Interfaces (Task 2 → Tasks 3–4):**
- `struct Version: Equatable, Comparable` — `init?(tag: String)`, `var displayString: String`.
- `struct ReleaseInfo` — `tag: String`, `pageURL: URL`, `dmgURL: URL?`, `notes: String`, `publishedAt: Date?`; `static func parse(from data: Data) -> ReleaseInfo?`.
- `struct UpdateSchedule` — `static let minimumInterval: TimeInterval`; `func shouldCheck(now: Date, lastCheck: Date?) -> Bool`.
- `struct SkipState` — `init(store: UserDefaults = .standard)`; `func isSkipped(tag: String) -> Bool`; `mutating func skip(tag: String)`.

**Interfaces (Task 3 → Task 4):**
- `final class UpdateChecker: ObservableObject` — `@Published private(set) var banner: BannerState?`; `init(currentVersion: Version?)`; `func checkForUpdates(manual: Bool)`; `func getUpdate()`; `func skip()`; `func dismiss()`; `struct BannerState { let info: ReleaseInfo; let newVersion: Version }`.

---

### Task 1: Fix release upload repo slug

**Files:**
- Modify: `SoundMix/build-dmg.sh` (the `gh release create` block, ~line 78)

**Interfaces:**
- Consumes: nothing.
- Produces: releases published under the canonical slug the checker queries; no code interface.

- [ ] **Step 1: Point `gh release create` at the canonical repo**

Change `--repo oleggohman/SoundAPP` to `--repo oleggohman/SoundMix`, with a one-line comment above it: the repo was renamed and the old slug still redirects, so nobody "fixes" it back.

- [ ] **Step 2: Verify the canonical repo is queryable**

Run: `gh api repos/oleggohman/SoundMix/releases/latest --jq .tag_name`
Expected: `v1.2.0-build-58` (or newer).

- [ ] **Step 3: Commit**

```bash
git add SoundMix/build-dmg.sh
git commit -m "fix(build): publish releases to canonical SoundMix repo slug

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Pure update-check logic in SoundMixCore (TDD)

**Files:**
- Create: `SoundMix/Sources/SoundMixCore/UpdateCheck.swift`
- Test: `SoundMix/Tests/main.swift` (append sections at the end)

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: the Task 2 interfaces above; Tasks 3–4 rely on those exact names.

- [ ] **Step 1: Write failing tests — `Version` parse/compare**

Append after the last existing section of `Tests/main.swift`:

```swift
// MARK: - Update check

section("Release tag parsing and ordering")
do {
    check(Version(tag: "v1.2.0-build-58") == Version(tag: "v1.2.0-build-58"), "equal tags are equal")
    check(Version(tag: "v1.2.0-build-9")! < Version(tag: "v1.2.0-build-58")!, "build 9 < build 58 numerically")
    check(Version(tag: "v1.3.0-build-1")! > Version(tag: "v1.2.9-build-99")!, "version triple beats build count")
    check(Version(tag: "v1.2.0-build-58")! > Version(tag: "v1.2.0-build-9")!, "58 > 9")
    check(Version(tag: "1.2.0-build-58") != nil, "leading v is optional")
    check(Version(tag: "v1.2.0") == nil, "tag without build number does not parse")
    check(Version(tag: "v1.2.0-beta.1-build-3") == nil, "prerelease segment rejects")
    check(Version(tag: "v1.2.0-build-x") == nil, "non-numeric build rejects")
    check(Version(tag: "v1.2-build-3") == nil, "two-component version rejects")
    check(Version(tag: "v1.2.0-build-58")!.displayString == "1.2.0 (build 58)", "display string")
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `cd SoundMix && bash run-tests.sh`
Expected: FAIL — use of undeclared type `Version`.

- [ ] **Step 3: Implement `Version` in `UpdateCheck.swift`**

Struct with `major`, `minor`, `patch`, `build: Int`. `init?(tag:)` strips an optional leading `v`, splits on the literal `"-build-"`, requires exactly three dot-separated integer components before it and one integer after; any failure returns nil. `Comparable` compares the tuple `(major, minor, patch, build)`. `displayString` is `"major.minor.patch (build N)"`.

- [ ] **Step 4: Run tests, verify pass**

Run: `bash run-tests.sh` → new section passes, failures = 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/SoundMixCore/UpdateCheck.swift Tests/main.swift
git commit -m "feat(core): parse and order SoundMix release tags

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

- [ ] **Step 6: Write failing tests — `ReleaseInfo` JSON parsing**

```swift
section("Release JSON parsing")
do {
    let json = """
    {"tag_name": "v1.2.0-build-58", "html_url": "https://github.com/oleggohman/SoundMix/releases/tag/v1.2.0-build-58",
     "body": "Notes here.", "published_at": "2026-10-17T09:00:00Z",
     "assets": [{"name": "SoundMix-1.2.0-build-58.dmg", "browser_download_url": "https://example.com/dmg"}]}
    """.data(using: .utf8)!
    let info = ReleaseInfo.parse(from: json)
    check(info != nil, "valid release JSON parses")
    check(info?.tag == "v1.2.0-build-58", "tag read")
    check(info?.pageURL.absoluteString.contains("v1.2.0-build-58") == true, "page URL read")
    check(info?.dmgURL != nil, "DMG asset URL extracted when the name matches the DMG pattern")
    check(info?.notes == "Notes here.", "notes read")
    check(ReleaseInfo.parse(from: "{\"tag_name\": \"latest\"}".data(using: .utf8)!) == nil,
          "tag that fails Version parsing yields nil")
    check(ReleaseInfo.parse(from: "{\"tag_name\": \"v1.2.0-build-58\"}".data(using: .utf8)!) != nil,
          "release with no assets still parses (dmgURL nil)")
}
```

- [ ] **Step 7: Run tests, verify fail** (`ReleaseInfo` undeclared).

- [ ] **Step 8: Implement `ReleaseInfo`**

Internal `Codable` mirror of the GitHub `/releases/latest` response: `tag_name`, `html_url`, `body`, `published_at` (ISO8601 date decoding), `assets: [Asset]` with `name` + `browser_download_url`. `dmgURL` is the first asset whose name matches the regex `^SoundMix-\d+\.\d+\.\d+-build-\d+\.dmg$`. `parse(from:)` returns nil when decoding fails **or** when `Version(tag: tag_name)` fails (Review Focus #1: an unparseable tag is not an update candidate).

- [ ] **Step 9: Run tests, verify pass; commit** `feat(core): parse GitHub release JSON into ReleaseInfo` (plus the Co-Authored-By line).

- [ ] **Step 10: Write failing tests — schedule + skip state**

```swift
section("Update schedule and skip state")
do {
    let now = Date(timeIntervalSince1970: 100_000)
    let schedule = UpdateSchedule()
    check(schedule.shouldCheck(now: now, lastCheck: nil), "no last check recorded means check")
    check(!schedule.shouldCheck(now: now, lastCheck: Date(timeIntervalSince1970: 99_000)),
          "checked 1000 s ago means wait")
    check(schedule.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-UpdateSchedule.minimumInterval - 1)),
          "past 24 h means check")
    check(!schedule.shouldCheck(now: now, lastCheck: now.addingTimeInterval(-UpdateSchedule.minimumInterval + 1)),
          "just inside 24 h means wait")

    let suite = UserDefaults(suiteName: "update-check-tests")!
    suite.removePersistentDomain(forName: "update-check-tests")
    var skip = SkipState(store: suite)
    check(!skip.isSkipped(tag: "v1.2.0-build-58"), "fresh state skips nothing")
    skip.skip(tag: "v1.2.0-build-58")
    check(skip.isSkipped(tag: "v1.2.0-build-58"), "skipped tag remembered")
    check(!skip.isSkipped(tag: "v1.2.0-build-59"), "other tags unaffected")
    let reread = SkipState(store: suite)
    check(reread.isSkipped(tag: "v1.2.0-build-58"), "skip survives re-reading the store")
    suite.removePersistentDomain(forName: "update-check-tests")
}
```

- [ ] **Step 11: Run tests, verify fail.**

- [ ] **Step 12: Implement `UpdateSchedule` + `SkipState`**

`UpdateSchedule.minimumInterval = 24 * 3600`; `shouldCheck(now:lastCheck:)` is pure — the caller owns persisting the last-check date. `SkipState` stores the skip list as `[String]` under key `"updateCheck.skippedTags"` in the injected store; `skip(tag:)` appends if absent. Both structs carry doc comments. Tests use a scratch `UserDefaults(suiteName:)` so they never touch the real domain.

- [ ] **Step 13: Run tests, verify pass; commit** `feat(core): 24 h schedule gate and skip-version state` (plus the Co-Authored-By line).

---

### Task 3: App-layer `UpdateChecker`

**Files:**
- Create: `SoundMix/Sources/SoundMixApp/UpdateChecker.swift`

**Interfaces:**
- Consumes: `Version`, `ReleaseInfo`, `UpdateSchedule`, `SkipState` (Task 2).
- Produces (consumed by Task 4):
  - `final class UpdateChecker: ObservableObject` — `@Published private(set) var banner: BannerState?`; `init(currentVersion: Version? = Bundle.main.version)`; `func checkForUpdates(manual: Bool)`; `func getUpdate()`; `func skip()`; `func dismiss()`.
  - `struct BannerState { let info: ReleaseInfo; let newVersion: Version }`.
  - `extension Bundle { var version: Version? }` (file-private is fine).

- [ ] **Step 1: Implement `UpdateChecker` per the Interfaces block**

No unit tests — repo convention keeps the app layer to build + listening verification (`PLAN.md` "Interactive and listening verification"). Behavior to implement:

- Bundle version: `CFBundleShortVersionString` + `CFBundleVersion` combined into `"v<short>-build-<build>"` and run through `Version(tag:)`; nil if either key is missing (Review Focus: no-plist CLI environments — treat nil current version as "cannot compare", stay silent, never banner).
- `checkForUpdates(manual: false)`: consult `UpdateSchedule.shouldCheck(now:lastCheck:)` with the persisted `"updateCheck.lastCheck"` date; skip silently if not due. `manual: true` always runs.
- Fetch `https://api.github.com/repos/oleggohman/SoundMix/releases/latest` on `DispatchQueue.global(qos: .utility)` with a 15 s request timeout and an `Accept: application/vnd.github+json` header; hop to main for publishes.
- Decide: parse `ReleaseInfo`; if nil, or `Version(tag:)` of the release tag is not newer than current → nothing (manual shows the up-to-date alert). If newer and not `SkipState.isSkipped` → `banner = BannerState(...)`. A newer-but-skipped tag does not banner (manual still reports it).
- Every completed attempt — success, HTTP error, 403/429 rate limit, network failure — stamps `"updateCheck.lastCheck"` to now (Review Focus #3: no retry loop within the window).
- Failure surfaces only when manual: show an `NSAlert` (see Step 2 copy). Automatic failures are silent.
- `getUpdate()` opens `banner.info.pageURL` via `NSWorkspace.shared.open`. `dismiss()` sets banner nil. `skip()` sets banner nil and records the tag in `SkipState`.
- Concurrency guard: ignore a check that arrives while one is in flight.
- Doc comments throughout, `Telemetry.swift` tone; class is `@MainActor`.

- [ ] **Step 2: Manual-result alert copy** (fixed text)

- Up to date: title `SoundMix is up to date`; message `You're running <current displayString> — the latest release.`
- Available: title `Update available`; message `<new displayString> is available. See the release page for details.`
- Failed: title `Could not check for updates`; message `GitHub didn't respond (offline or rate-limited). Try again later.`

- [ ] **Step 3: Build**

Run: `cd SoundMix && bash build.sh`
Expected: `==> Built build/SoundMix.app` with the version line; build number auto-increments past 58.

- [ ] **Step 4: Commit**

```bash
git add Sources/SoundMixApp/UpdateChecker.swift
git commit -m "feat(app): UpdateChecker networking and published update state

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: UI — menu item, launch check, banner

**Files:**
- Create: `SoundMix/Sources/SoundMixApp/UpdateBanner.swift`
- Modify: `SoundMix/Sources/SoundMixApp/main.swift`
- Modify: `SoundMix/Sources/SoundMixApp/ContentView.swift` (`contentArea`, lines ~40-45)

**Interfaces:**
- Consumes: `UpdateChecker` (Task 3); existing `CZ.Color`, `CZ.Typography`, `CZ.Spacing`, `CZButton`.
- Produces: the user-visible update flow.

- [ ] **Step 1: Write `UpdateBanner.swift`**

A SwiftUI view taking `@ObservedObject var checker: UpdateChecker`. When `checker.banner` is non-nil it renders a `CZAlert`-styled banner: `arrow.down.circle.fill` icon in `CZ.Color.blue`, headline `SoundMix <newVersion.displayString> is available.`, subline `The release page opens in your browser; download the DMG and drag it to Applications.`, and three actions — `Get Update` (`CZButton`, calls `checker.getUpdate()`), `Skip This Version` and a dismiss ✕ (call `checker.skip()` / `checker.dismiss()`). Nil banner renders nothing (`EmptyView`). Layout follows `CZAlert` in `Components.swift:270` (padding `CZ.Spacing.lg`, tinted background at 0.2 opacity, corner radius `CZ.Radius.medium`).

- [ ] **Step 2: Wire `main.swift`**

- `SoundMixApp` gains `@StateObject private var checker = UpdateChecker()`.
- The Window content chain gains `.environmentObject(checker)` next to the existing `.environmentObject(model)` and `.onAppear { checker.checkForUpdates(manual: false) }` alongside the existing `reloadPEQWarnings` onAppear.
- In `.commands`, after `CommandGroup(replacing: .newItem) {}`, add:

```swift
CommandGroup(after: .newItem) {
    Button("Check for Updates…") { checker.checkForUpdates(manual: true) }
}
```

- [ ] **Step 3: Render the banner in `ContentView.contentArea`**

Insert `UpdateBanner()` directly above the existing `if let error = model.errorMessage { CZAlert(kind: .error, message: error) }` block, with `@EnvironmentObject var checker: UpdateChecker` added to `ContentView`.

- [ ] **Step 4: Build**

Run: `bash build.sh` → succeeds.

- [ ] **Step 5: Manual smoke test (implementer's machine; the agent sandbox cannot launch GUI apps)**

Launch the built app and confirm: menu item shows the up-to-date alert (running build 59 > latest 58 — this also exercises Review Focus #5 in the real app); no banner on same/newer version; launch makes no more than one network call. Record observations in the commit body. Items that need a genuinely newer release (banner appears, skip persists across relaunch) stay in `PLAN.md`'s interactive-verification list.

- [ ] **Step 6: Commit**

```bash
git add Sources/SoundMixApp/UpdateBanner.swift Sources/SoundMixApp/main.swift Sources/SoundMixApp/ContentView.swift
git commit -m "feat(app): update banner, launch check, and Check for Updates menu item

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: Update PLAN.md and verification notes

**Files:**
- Modify: `PLAN.md` (repo root, git-ignored)
- Modify: `SoundMix/VERIFICATION.md`

**Interfaces:** none.

- [ ] **Step 1: Move the update-mechanism section out of Remaining** in `PLAN.md`, noting: implemented scope (24 h launch check, menu item, banner + skip, phase-1 browser handoff), the flat-file deviation from the originally sketched `UpdateCheck/` subfolder (build scripts glob flat), and the remaining interactive items (banner on a real newer release, skip persistence across relaunch, offline launch silence).

- [ ] **Step 2: Append to `SoundMix/VERIFICATION.md`**: date, build number, pure-logic test counts, build pass, manual smoke observations.

- [ ] **Step 3: Commit** (`SoundMix/VERIFICATION.md` is tracked; `PLAN.md` is ignored, so it is not part of the commit):

```bash
git add SoundMix/VERIFICATION.md
git commit -m "docs: record update-check verification

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Self-Review

1. **Spec coverage:** 24 h launch check ✓ (T2 schedule + T3 stamping + T4 onAppear); silent on failure ✓ (T3); manual menu item ✓ (T4); `/releases/latest` + `tag_name` + numeric compare ✓ (T2); build-number-before-version ordering ✓ (T2); skip-this-version ✓ (T2 + T3/T4); phase-1 browser handoff ✓ (T3 `getUpdate` + T4 copy); no Sparkle ✓; rate-limit handling ✓ (T3); core/app module split ✓ (T2/T3); release flow unchanged ✓ (T1 only corrects the slug). Gap check: none.
2. **Step scan:** each step is one action with a checkable result; no TBDs; algorithm bodies appear only where the signature and tests don't determine them.
3. **Type consistency:** `Version(tag:)`/`displayString`, `ReleaseInfo.parse(from:)`, `UpdateSchedule.shouldCheck(now:lastCheck:)`, `SkipState(store:/isSkipped/skip)`, `UpdateChecker`/`BannerState` used identically across tasks.
4. **Review Focus:** five lines, each with a pinning test in T2 or explicit handling in T3; the no-plist case is documented rather than unit-tested (app layer, by convention).
5. **Proportion:** ~4 pages for a feature spanning pure logic, networking, UI, and build plumbing — proportional to the spec section it implements.
