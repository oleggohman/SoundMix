import Foundation

/// Isolated graphical edits. Untouched documents retain their original text.
public struct PEQEditDraft {
    public enum Stage: String, CaseIterable, Identifiable {
        case global = "Global", left = "Speaker L", right = "Speaker R"
        public var id: String { rawValue }
    }
    public let originalGlobal: String
    public let originalSpeaker: String
    public let swapsOutputs: Bool
    private var global: APOParser.Document
    private var speaker: APOParser.Document
    private var changedGlobal = false
    private var changedSpeaker = false

    public init(global: String, speaker: String, swapsOutputs: Bool) {
        originalGlobal = global
        originalSpeaker = speaker
        self.swapsOutputs = swapsOutputs
        self.global = APOParser.parse(global)
        self.speaker = APOParser.parse(speaker)
    }

    public var warnings: [String] { global.warnings + speaker.warnings }
    public var hasChanges: Bool { globalText != originalGlobal || speakerText != originalSpeaker }
    private func channel(_ stage: Stage) -> Int {
        if stage == .global { return global.channels.keys.min() ?? 0 }
        return (stage == .left) != swapsOutputs ? 0 : 1
    }
    public func profile(_ stage: Stage) -> PEQProfile {
        stage == .global ? global.firstProfile : speaker.profile(forChannel: channel(stage))
    }
    public mutating func setProfile(_ input: PEQProfile, for stage: Stage) {
        guard warnings.isEmpty else { return }
        // Drags, sliders and typed fields all land here; rebuilding each filter
        // through `PEQFilter.init` clamps Fc, gain and Q to three decimals.
        var profile = input
        profile.filters = input.filters.map {
            PEQFilter(enabled: $0.enabled, kind: $0.kind, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q)
        }
        guard profile != self.profile(stage) else { return }
        if stage == .global {
            global.channels[channel(stage)] = profile
            changedGlobal = true
        } else {
            // Materialize both fallbacks before editing one ear so the other ear is preserved.
            let left = speaker.profile(forChannel: 0), right = speaker.profile(forChannel: 1)
            speaker.channels[0] = left
            speaker.channels[1] = right
            speaker.channels[channel(stage)] = profile
            changedSpeaker = true
        }
    }
    /// Lowest frequency a band can be dragged to, matching the inspector field.
    public static let minimumFrequency = 20.0

    /// Drag resolution: 1 Hz below 1 kHz and 10 Hz above it, so a horizontal
    /// drag lands on a value somebody would have typed rather than 1037.4183 Hz.
    public static func quantisedFrequency(_ hz: Double, maxFrequency: Double) -> Double {
        let upper = max(minimumFrequency, maxFrequency)
        let clamped = min(upper, max(minimumFrequency, hz))
        let step = clamped < 1000 ? 1.0 : 10.0
        return min(upper, max(minimumFrequency, (clamped / step).rounded() * step))
    }

    /// Move one band. Both axes are optional, so a vertical-only drag leaves the
    /// frequency exactly as it was and vice versa; Q, kind and the other bands
    /// are never touched. The band list keeps its order: APO filters are a list
    /// and the plot numbers them by position, so dragging one past another must
    /// not renumber the point under the cursor.
    public mutating func setBand(at index: Int, for stage: Stage,
                                 gainDB: Double? = nil, frequency: Double? = nil,
                                 maxFrequency: Double = 20_000) {
        var p = profile(stage)
        guard p.filters.indices.contains(index) else { return }
        if let gainDB, gainDB.isFinite {
            p.filters[index].gainDB = min(24, max(-24, gainDB))
        }
        if let frequency, frequency.isFinite {
            p.filters[index].frequency = Self.quantisedFrequency(frequency, maxFrequency: maxFrequency)
        }
        setProfile(p, for: stage)
    }

    public mutating func setGain(_ gain: Double, at index: Int, for stage: Stage) {
        setBand(at: index, for: stage, gainDB: gain)
    }

    public mutating func setFrequency(_ frequency: Double, at index: Int, for stage: Stage,
                                      maxFrequency: Double = 20_000) {
        setBand(at: index, for: stage, frequency: frequency, maxFrequency: maxFrequency)
    }

    /// Silence a band without destroying it, the non-fatal twin of `removeFilter`.
    public mutating func setEnabled(_ enabled: Bool, at index: Int, for stage: Stage) {
        var p = profile(stage)
        guard p.filters.indices.contains(index) else { return }
        p.filters[index].enabled = enabled
        setProfile(p, for: stage)
    }

    @discardableResult
    public mutating func removeFilter(at index: Int, for stage: Stage) -> Bool {
        var p = profile(stage)
        guard p.filters.indices.contains(index) else { return false }
        p.filters.remove(at: index)
        setProfile(p, for: stage)
        return profile(stage).filters.count == p.filters.count
    }

    /// Which band the editor should select after removing `index` from a list of
    /// `count`: the one that slid into its place, or the new last band, rather
    /// than nothing at all.
    public static func selectionAfterRemoval(of index: Int, count: Int) -> Int? {
        let remaining = count - 1
        guard remaining > 0, index >= 0 else { return nil }
        return min(index, remaining - 1)
    }
    public func referenceProfile(_ stage: Stage) -> PEQProfile {
        PEQEditDraft(global: originalGlobal, speaker: originalSpeaker, swapsOutputs: swapsOutputs).profile(stage)
    }
    public mutating func reset() {
        self = PEQEditDraft(global: originalGlobal, speaker: originalSpeaker, swapsOutputs: swapsOutputs)
    }
    /// Called after Apply succeeds so subsequent Reset only discards unapplied edits.
    public mutating func acceptChanges() {
        self = PEQEditDraft(global: globalText, speaker: speakerText, swapsOutputs: swapsOutputs)
    }
    public func combined(_ side: Stage) -> PEQProfile {
        var p = profile(.global)
        let ear = profile(side)
        p.filters += ear.filters
        p.preampDB += ear.preampDB
        return p
    }
    public var globalText: String { changedGlobal ? Self.text(global) : originalGlobal }
    public var speakerText: String { changedSpeaker ? Self.text(speaker) : originalSpeaker }

    private static func text(_ document: APOParser.Document) -> String {
        document.channels.keys.sorted().map { channel in
            let p = document.channels[channel]!
            func number(_ value: Double) -> String {
                String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
            }
            var lines = ["Channel: \(channel + 1)", "Preamp: \(number(p.preampDB)) dB"]
            for (index, filter) in p.filters.enumerated() {
                let kind = filter.kind == .peaking ? "PK" : (filter.kind == .lowShelf ? "LSC" : "HSC")
                lines.append("Filter \(index + 1): \(filter.enabled ? "ON" : "OFF") \(kind) Fc \(number(filter.frequency)) Hz Gain \(number(filter.gainDB)) dB Q \(number(filter.q))")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
