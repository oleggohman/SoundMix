import Foundation

/// A parsed release tag of the form `v<major>.<minor>.<patch>-build-<n>`.
///
/// Tags are compared numerically: build 9 sorts before build 58, and a
/// higher version component outranks any build number.
struct Version: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int
    let build: Int

    /// Parses a release tag such as `v1.2.0-build-58`.
    ///
    /// Returns nil unless the tag carries the `v` prefix, exactly three
    /// dot-separated numeric components, and a numeric `-build-` suffix;
    /// pre-release tags (`v1.2.0-beta.1-build-3`) are rejected outright.
    static func parse(_ tag: String) -> Version? {
        guard tag.hasPrefix("v") else { return nil }
        let body = tag.dropFirst()
        guard let dash = body.range(of: "-build-") else { return nil }
        let numbers = String(body[body.startIndex..<dash.lowerBound])
            .split(separator: ".", omittingEmptySubsequences: false)
        let buildText = String(body[dash.upperBound...])
        guard numbers.count == 3 else { return nil }
        guard let major = Int(numbers[0]), let minor = Int(numbers[1]),
              let patch = Int(numbers[2]), let build = Int(buildText) else { return nil }
        return Version(major: major, minor: minor, patch: patch, build: build)
    }

    /// Orders versions by semantic components first, build number last.
    static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build)
            < (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }

    /// A human-readable form for menus and the update banner.
    var displayString: String { "\(major).\(minor).\(patch) (build \(build))" }
}

/// The parts of a GitHub release the update check cares about, decoded from
/// the `/releases/latest` endpoint's JSON.
struct ReleaseInfo: Equatable {
    /// The release version parsed from `tag_name`.
    let version: Version
    /// The human-facing release page, from `html_url`.
    let pageURL: URL
    /// The bundled DMG asset, if the release ships one.
    let dmgURL: URL?
    /// The release notes body, empty when the release has none.
    let notes: String
    /// When the release went out, from `published_at`.
    let published: Date?

    /// Decodes the `/releases/latest` JSON payload.
    ///
    /// Returns nil when the payload is not JSON, the tag does not parse, the
    /// entry is a draft or pre-release, or `html_url` is missing. The DMG
    /// asset is located by its `SoundMix-<version>-build-<n>.dmg` name; any
    /// other asset is ignored.
    static func parse(from data: Data) -> ReleaseInfo? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              let version = Version.parse(raw.tagName),
              !(raw.draft ?? false), !(raw.prerelease ?? false),
              let pageURL = URL(string: raw.htmlURL) else { return nil }
        let dmg = raw.assets?.first { Self.dmgPattern.matches($0.name) }
            .flatMap { URL(string: $0.browserDownloadURL) }
        return ReleaseInfo(version: version,
                           pageURL: pageURL,
                           dmgURL: dmg,
                           notes: raw.body ?? "",
                           published: Self.dates.date(from: raw.publishedAt ?? ""))
    }

    /// GitHub ships DMGs named `SoundMix-1.2.0-build-58.dmg`; zip archives
    /// and source bundles must not be mistaken for the installer.
    private static let dmgPattern = try! NSRegularExpression(
        pattern: #"^SoundMix-\d+\.\d+\.\d+-build-\d+\.dmg$"#)

    /// GitHub timestamps are ISO 8601 with a `Z` suffix.
    private static let dates = ISO8601DateFormatter()

    /// Field-for-field mirror of the endpoint's JSON, minus everything the
    /// update check never reads.
    private struct Raw: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let publishedAt: String?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease
            case publishedAt = "published_at"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}

extension NSRegularExpression {
    /// Matches the whole string, the only mode release names ever need.
    fileprivate func matches(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return firstMatch(in: string, range: range) != nil
    }
}
