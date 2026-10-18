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
