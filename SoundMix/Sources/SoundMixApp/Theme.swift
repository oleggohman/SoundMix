import SwiftUI
import AppKit

/// SoundMix design tokens. Colours are never written as literals elsewhere in
/// the app — every surface, border and accent comes from this file.
public enum CZ {

    // MARK: Colour tokens

    public enum Color {
        // Primary brand
        public static let blue        = SwiftUI.Color(hex: 0x2FA8F7)
        public static let purple      = SwiftUI.Color(hex: 0x5D77F9)
        public static let pink        = SwiftUI.Color(hex: 0xAF85F5)
        public static let darkBlue    = SwiftUI.Color(hex: 0x0E1E4D)
        public static let mutedBlue   = SwiftUI.Color(hex: 0x323F68)

        // Gray spectrum
        public static let white       = SwiftUI.Color(hex: 0xFFFFFF)
        public static let black       = SwiftUI.Color(hex: 0x000000)
        public static let ghostGray   = SwiftUI.Color(hex: 0xE4E5EB)
        public static let lightestGray = SwiftUI.Color(hex: 0xEDEDED)
        public static let mutedGray   = SwiftUI.Color(hex: 0xCED0D9)
        public static let lightGray   = SwiftUI.Color(hex: 0xAAAEBD)
        public static let mediumGray  = SwiftUI.Color(hex: 0x666A80)

        // Blue spectrum
        public static let paleBlue    = SwiftUI.Color(hex: 0xEEF2FB)
        public static let lightestBlue = SwiftUI.Color(hex: 0xDFE4FE)
        public static let lightBlue   = SwiftUI.Color(hex: 0xC5D3F4)
        public static let mediumBlue  = SwiftUI.Color(hex: 0x9FB2E8)

        // Alert / status
        public static let red         = SwiftUI.Color(hex: 0xF96C5D)
        public static let orange      = SwiftUI.Color(hex: 0xF8A23A)

        // Semantic aliases
        public static let defaultBackground   = white
        public static let primaryBackground   = darkBlue
        public static let secondaryBackground = paleBlue
        public static let defaultText         = black
        public static let invertedText        = white
        public static let captionText         = lightGray
        public static let dangerText          = red
    }

    // MARK: Spacing scale

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
        public static let xl: CGFloat = 32
        public static let xxl: CGFloat = 40
        public static let xxxl: CGFloat = 48
    }

    // MARK: Radius

    public enum Radius {
        public static let tiny: CGFloat = 4
        public static let medium: CGFloat = 16
        public static let large: CGFloat = 20
        public static let pill: CGFloat = 40
    }

    // MARK: Motion

    public enum Motion {
        public static let instant = Animation.easeInOut(duration: 0.1)
        public static let quick   = Animation.easeInOut(duration: 0.15)
        public static let normal  = Animation.easeInOut(duration: 0.25)
    }

    // MARK: Typography
    //
    // Landour carries body text and headings; Wix Madefor carries nav items and
    // buttons. Both fall back to Arial / Helvetica when the brand files are not
    // installed on the machine.

    public enum Typography {
        public enum Weight {
            case regular, medium, semibold
            var landourText: String {
                switch self {
                case .regular:  return "Landour-RegularText"
                case .medium:   return "Landour-MediumText"
                case .semibold: return "Landour-SemiBoldText"
                }
            }
            var landourDisplay: String {
                switch self {
                case .regular:  return "Landour-RegularDisplay"
                case .medium:   return "Landour-MediumDisplay"
                case .semibold: return "Landour-SemiBoldDisplay"
                }
            }
            var madefor: String {
                switch self {
                case .regular:  return "WixMadeforDisplay-Regular"
                case .medium:   return "WixMadeforDisplay-Medium"
                case .semibold: return "WixMadeforDisplay-SemiBold"
                }
            }
            var systemFallback: Font.Weight {
                switch self {
                case .regular:  return .regular
                case .medium:   return .medium
                case .semibold: return .semibold
                }
            }
        }

        private static let installed: Set<String> = {
            Set(NSFontManager.shared.availableFonts)
        }()

        static func resolve(_ postScript: String, size: CGFloat, fallback: Font.Weight) -> Font {
            if installed.contains(postScript) { return .custom(postScript, size: size) }
            for name in ["Arial", "Helvetica"] where installed.contains(name) {
                return .custom(name, size: size)
            }
            return .system(size: size, weight: fallback)
        }

        /// Body and headings.
        public static func body(_ size: CGFloat, _ weight: Weight = .medium, display: Bool = false) -> Font {
            resolve(display ? weight.landourDisplay : weight.landourText,
                    size: size, fallback: weight.systemFallback)
        }
        /// Nav items and buttons.
        public static func ui(_ size: CGFloat, _ weight: Weight = .semibold) -> Font {
            resolve(weight.madefor, size: size, fallback: weight.systemFallback)
        }

        // Type scale
        public static var largeTitle: Font { body(40, .semibold, display: true) }
        public static var title: Font      { body(20, .semibold) }
        public static var subtitle: Font   { body(16, .medium) }
        public static var bodySmall: Font  { body(14, .medium) }
        public static var input: Font      { body(15, .medium) }
        public static var caption: Font    { body(12, .medium) }
        public static var label: Font      { body(10, .semibold) }
        /// Tabular figures for meters and coefficient tables.
        public static func mono(_ size: CGFloat) -> Font {
            .system(size: size, weight: .medium, design: .monospaced)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
