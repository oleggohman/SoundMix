import Foundation

/// A complete, named EQ state: both the global PEQ and the speaker correction.
///
/// The original app saved only the routing PEQ, as a blob inside one shared
/// preferences file, so a single bad write took every profile with it. These
/// are one file each, human-readable, and safe to copy between machines.
public struct EQProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var globalText: String
    public var speakerText: String
    /// The earphone curves this EQ was written for — one per ear, so an IEM
    /// measured as a matched pair can be read against its own correction.
    /// Either side may stand alone; a single-curve measurement lands in `left`.
    public var measurementLeft: FrequencyResponse?
    public var measurementRight: FrequencyResponse?
    /// The reference curve the correction aims at — JM-1, a Harman variant, or
    /// a house target. Supplied as a file; nothing is assumed about its shape.
    public var target: FrequencyResponse?
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), name: String, notes: String = "",
                globalText: String = "", speakerText: String = "",
                measurementLeft: FrequencyResponse? = nil,
                measurementRight: FrequencyResponse? = nil,
                target: FrequencyResponse? = nil,
                created: Date = Date(), modified: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.globalText = globalText
        self.speakerText = speakerText
        self.measurementLeft = measurementLeft
        self.measurementRight = measurementRight
        self.target = target
        self.created = created
        self.modified = modified
    }

    public var hasMeasurement: Bool { measurementLeft != nil || measurementRight != nil }

    /// Whichever side is present, preferring left — for anything that needs a
    /// single representative curve.
    public var anyMeasurement: FrequencyResponse? { measurementLeft ?? measurementRight }

    public func measurement(for side: Side) -> FrequencyResponse? {
        side == .left ? measurementLeft : measurementRight
    }

    public enum Side: String, CaseIterable, Codable, Sendable, Identifiable {
        case left, right
        public var id: String { rawValue }
        public var label: String { self == .left ? "Left" : "Right" }
        public var short: String { self == .left ? "L" : "R" }
    }

    // Profiles saved before measurements were split per ear used a single
    // `measurement` key. Decode it into the left side so nothing is lost.
    private enum CodingKeys: String, CodingKey {
        case id, name, notes, globalText, speakerText
        case measurementLeft, measurementRight, measurement, target
        case created, modified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        globalText = try c.decodeIfPresent(String.self, forKey: .globalText) ?? ""
        speakerText = try c.decodeIfPresent(String.self, forKey: .speakerText) ?? ""
        let legacy = try c.decodeIfPresent(FrequencyResponse.self, forKey: .measurement)
        measurementLeft = try c.decodeIfPresent(FrequencyResponse.self, forKey: .measurementLeft) ?? legacy
        measurementRight = try c.decodeIfPresent(FrequencyResponse.self, forKey: .measurementRight)
        target = try c.decodeIfPresent(FrequencyResponse.self, forKey: .target)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(notes, forKey: .notes)
        try c.encode(globalText, forKey: .globalText)
        try c.encode(speakerText, forKey: .speakerText)
        try c.encodeIfPresent(measurementLeft, forKey: .measurementLeft)
        try c.encodeIfPresent(measurementRight, forKey: .measurementRight)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encode(created, forKey: .created)
        try c.encode(modified, forKey: .modified)
    }

    public var globalProfile: PEQProfile {
        globalText.isEmpty ? .flat : APOParser.parse(globalText).firstProfile
    }
    public var speakerLeft: PEQProfile {
        speakerText.isEmpty ? .flat : APOParser.parse(speakerText).profile(forChannel: 0)
    }
    public var speakerRight: PEQProfile {
        speakerText.isEmpty ? .flat : APOParser.parse(speakerText).profile(forChannel: 1)
    }

    /// Short description for the library list.
    public var summary: String {
        let g = globalProfile.activeFilterCount
        let l = speakerLeft.activeFilterCount
        let r = speakerRight.activeFilterCount
        var parts: [String] = []
        if g > 0 { parts.append("\(g) global") }
        if l > 0 || r > 0 { parts.append("\(max(l, r)) speaker") }
        if parts.isEmpty { parts.append("empty") }
        let preamp = globalProfile.preampDB
        if preamp != 0 { parts.append(String(format: "preamp %+.1f dB", preamp)) }
        switch (measurementLeft != nil, measurementRight != nil) {
        case (true, true):  parts.append("measured L+R")
        case (true, false), (false, true): parts.append("measured, one ear")
        case (false, false): break
        }
        if let t = target { parts.append("vs \(t.name)") }
        return parts.joined(separator: " · ")
    }

    /// Largest boost anywhere in the audible band — the number that tells you
    /// whether a profile will cost you headroom.
    public func peakBoostDB(sampleRate: Double = 48_000) -> Double {
        var worst = -200.0
        for profile in [globalProfile, speakerLeft, speakerRight] {
            let cascade = profile.cascade(sampleRate: sampleRate)
            for point in EQProfile.probeFrequencies {
                worst = max(worst, cascade.magnitudeDB(at: point, sampleRate: sampleRate))
            }
        }
        return worst
    }

    static let probeFrequencies: [Double] = {
        (0...120).map { 20 * pow(10, Double($0) / 120 * 3) }   // 20 Hz … 20 kHz, log spaced
    }()
}

/// File-backed profile library. One JSON file per profile in a folder the user
/// can open, back up, or put under version control.
public final class EQProfileLibrary {

    public private(set) var profiles: [EQProfile] = []
    private let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SoundMix/EQ Profiles", isDirectory: true)
            self.directory = base
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    public var folderURL: URL { directory }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        profiles = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(EQProfile.self, from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func url(for profile: EQProfile) -> URL {
        directory.appendingPathComponent("\(profile.id.uuidString).json")
    }

    @discardableResult
    public func save(_ profile: EQProfile) throws -> EQProfile {
        var p = profile
        p.modified = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(p)
        try data.write(to: url(for: p), options: .atomic)
        reload()
        return p
    }

    public func delete(_ profile: EQProfile) throws {
        try FileManager.default.removeItem(at: url(for: profile))
        reload()
    }

    public func duplicate(_ profile: EQProfile) throws -> EQProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = uniqueName(basedOn: profile.name)
        copy.created = Date()
        return try save(copy)
    }

    public func rename(_ profile: EQProfile, to newName: String) throws -> EQProfile {
        var p = profile
        p.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.name.isEmpty { p.name = profile.name }
        return try save(p)
    }

    /// A name no existing profile uses, by appending “copy”, “copy 2”, …
    public func uniqueName(basedOn base: String) -> String {
        let existing = Set(profiles.map(\.name))
        var candidate = "\(base) copy"
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base) copy \(n)"
            n += 1
        }
        return candidate
    }

    public func profile(named name: String) -> EQProfile? {
        profiles.first { $0.name == name }
    }

    /// Import a REW / Equalizer APO text file as a new profile.
    @discardableResult
    public func importAPO(text: String, name: String, asSpeakerCorrection: Bool) throws -> EQProfile {
        let p = EQProfile(name: name,
                          notes: "Imported from a REW / Equalizer APO file.",
                          globalText: asSpeakerCorrection ? "" : text,
                          speakerText: asSpeakerCorrection ? text : "")
        return try save(p)
    }

    /// Render a profile back out as REW / Equalizer APO text.
    public func exportAPO(_ profile: EQProfile, speakerCorrection: Bool) -> String {
        speakerCorrection ? profile.speakerText : profile.globalText
    }

    // MARK: - Portable import / export

    /// What an exported `.dmxeq` file contains. A bundle holds any number of
    /// profiles, so one file can carry a whole library between machines.
    public struct Bundle: Codable, Sendable {
        public var format: String
        public var version: Int
        public var exported: Date
        public var profiles: [EQProfile]

        public init(profiles: [EQProfile]) {
            self.format = "soundmix-eq"
            self.version = 1
            self.exported = Date()
            self.profiles = profiles
        }
    }

    public static let fileExtension = "smeq"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func exportData(_ profiles: [EQProfile]) throws -> Data {
        try Self.encoder.encode(Bundle(profiles: profiles))
    }

    public enum ImportError: LocalizedError {
        case unreadable
        case empty
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file is not a SoundMix EQ export or a REW / Equalizer APO text file."
            case .empty:      return "That file contains no filters."
            }
        }
    }

    /// Accepts a `.dmxeq` bundle, a single exported profile, or raw APO text.
    /// Imported profiles always get a fresh id, so importing never overwrites
    /// a profile you already have.
    @discardableResult
    public func importData(_ data: Data, fallbackName: String,
                           apoAsSpeakerCorrection: Bool = false) throws -> [EQProfile] {
        if let bundle = try? Self.decoder.decode(Bundle.self, from: data), !bundle.profiles.isEmpty {
            return try bundle.profiles.map { try adoptAndSave($0) }
        }
        if let single = try? Self.decoder.decode(EQProfile.self, from: data) {
            return [try adoptAndSave(single)]
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.unreadable }
        let parsed = APOParser.parse(text).firstProfile
        guard !parsed.filters.isEmpty || parsed.preampDB != 0 else { throw ImportError.empty }
        return [try importAPO(text: text, name: uniqueImportName(fallbackName),
                          asSpeakerCorrection: apoAsSpeakerCorrection)]
    }

    private func adoptAndSave(_ profile: EQProfile) throws -> EQProfile {
        var p = profile
        p.id = UUID()
        p.name = uniqueImportName(profile.name)
        return try save(p)
    }

    /// Keeps the incoming name when it is free, otherwise appends a number.
    public func uniqueImportName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Imported" : trimmed
        let existing = Set(profiles.map(\.name))
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}

public extension PEQProfile {
    /// Text form, so edits made anywhere can round-trip back to a file.
    func apoText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", preampDB)]
        for (index, f) in filters.enumerated() {
            let kind: String
            switch f.kind {
            case .peaking:   kind = "PK"
            case .lowShelf:  kind = "LSC"
            case .highShelf: kind = "HSC"
            }
            lines.append(String(format: "Filter %d: %@ %@ Fc %g Hz Gain %.2f dB Q %.3f",
                                index + 1, f.enabled ? "ON" : "OFF", kind, f.frequency, f.gainDB, f.q))
        }
        return lines.joined(separator: "\n")
    }
}
