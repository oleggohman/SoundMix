import Foundation

/// A single bed channel in the canonical 9.1.6 order used by the renderer.
///
/// The order is identical to the one the original Downmix Renderer uses
/// (`L,R,C,LFE,Ls,Rs,Lrs,Rrs,Lw,Rw,Ltf,Rtf,Ltm,Rtm,Ltr,Rtr`) so that input
/// maps and PEQ profiles carry over unchanged.
public enum BedChannel: Int, CaseIterable, Codable, Sendable {
    case l = 0, r, c, lfe, ls, rs, lrs, rrs, lw, rw, ltf, rtf, ltm, rtm, ltr, rtr

    public static let count = 16

    public var shortName: String {
        switch self {
        case .l:   return "L"
        case .r:   return "R"
        case .c:   return "C"
        case .lfe: return "LFE"
        case .ls:  return "Ls"
        case .rs:  return "Rs"
        case .lrs: return "Lrs"
        case .rrs: return "Rrs"
        case .lw:  return "Lw"
        case .rw:  return "Rw"
        case .ltf: return "Ltf"
        case .rtf: return "Rtf"
        case .ltm: return "Ltm"
        case .rtm: return "Rtm"
        case .ltr: return "Ltr"
        case .rtr: return "Rtr"
        }
    }

    public var longName: String {
        switch self {
        case .l:   return "Front Left"
        case .r:   return "Front Right"
        case .c:   return "Center"
        case .lfe: return "LFE"
        case .ls:  return "Side Surround Left"
        case .rs:  return "Side Surround Right"
        case .lrs: return "Rear Surround Left"
        case .rrs: return "Rear Surround Right"
        case .lw:  return "Wide Left"
        case .rw:  return "Wide Right"
        case .ltf: return "Top Front Left"
        case .rtf: return "Top Front Right"
        case .ltm: return "Top Middle Left"
        case .rtm: return "Top Middle Right"
        case .ltr: return "Top Rear Left"
        case .rtr: return "Top Rear Right"
        }
    }

    /// Which horizontal side the channel sits on. `nil` means it is centred.
    public enum Side: Sendable { case left, right }
    public var side: Side? {
        switch self {
        case .c, .lfe: return nil
        case .l, .ls, .lrs, .lw, .ltf, .ltm, .ltr: return .left
        case .r, .rs, .rrs, .rw, .rtf, .rtm, .rtr: return .right
        }
    }

    /// Functional group, used to apply a coefficient to a whole tier at once.
    public enum Group: String, CaseIterable, Sendable {
        case front = "Front L/R"
        case center = "Center"
        case lfe = "LFE"
        case wide = "Wides"
        case sideSurround = "Side surrounds"
        case rearSurround = "Rear surrounds"
        case heightFront = "Heights front"
        case heightMiddle = "Heights middle"
        case heightRear = "Heights rear"
    }

    public var group: Group {
        switch self {
        case .l, .r:     return .front
        case .c:         return .center
        case .lfe:       return .lfe
        case .lw, .rw:   return .wide
        case .ls, .rs:   return .sideSurround
        case .lrs, .rrs: return .rearSurround
        case .ltf, .rtf: return .heightFront
        case .ltm, .rtm: return .heightMiddle
        case .ltr, .rtr: return .heightRear
        }
    }
}

/// A named source layout, expressed as a 1-based input map over the 16 bed slots.
/// `0` means the bed slot is unused (muted), exactly as in the original app.
public struct LayoutPreset: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var map: [Int]           // 16 entries, 1-based device channel or 0
    public var id: String { name }

    public init(name: String, map: [Int]) {
        precondition(map.count == BedChannel.count, "input map must have 16 entries")
        self.name = name
        self.map = map
    }

    /// Bed channels that actually carry signal under this map.
    public var activeChannels: [BedChannel] {
        BedChannel.allCases.filter { map[$0.rawValue] > 0 }
    }

    /// Highest device channel the map refers to; 0 when nothing is mapped.
    public var requiredInputChannels: Int { map.max() ?? 0 }

    public static let all: [LayoutPreset] = [
        LayoutPreset(name: "9.1.6", map: Array(1...16)),
        LayoutPreset(name: "7.1.4", map: [1,2,3,4,5,6,7,8,0,0,9,10,0,0,11,12]),
        LayoutPreset(name: "7.1.2", map: [1,2,3,4,5,6,7,8,0,0,0,0,9,10,0,0]),
        LayoutPreset(name: "7.1",   map: [1,2,3,4,5,6,7,8,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "5.1.4", map: [1,2,3,4,5,6,0,0,0,0,7,8,0,0,9,10]),
        LayoutPreset(name: "5.1.2", map: [1,2,3,4,5,6,0,0,0,0,0,0,7,8,0,0]),
        LayoutPreset(name: "5.1",   map: [1,2,3,4,5,6,0,0,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "4.0 quad", map: [1,2,0,0,3,4,0,0,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "3.1",   map: [1,2,3,4,0,0,0,0,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "3.0",   map: [1,2,3,0,0,0,0,0,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "2.1",   map: [1,2,0,3,0,0,0,0,0,0,0,0,0,0,0,0]),
        LayoutPreset(name: "2.0 stereo", map: [1,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0]),
    ]

    public static let nativeBed = LayoutPreset.all[0]
}
