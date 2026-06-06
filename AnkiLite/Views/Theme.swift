import SwiftUI

/// Centralized, deliberately restrained visual style.
///
/// The goal is a calm, native-feeling appearance: neutral grays, a single
/// understated accent, flat surfaces, hairline separators, and SF Symbols
/// instead of decorative emoji or gradients.
enum Theme {

    // MARK: - Surfaces (dark)

    /// App background — near-black neutral, not pure black.
    static let background = Color(hex: "#111113")
    /// Elevated surface (cards, rows).
    static let surface = Color(hex: "#1b1b1e")
    /// A slightly higher surface for nested content.
    static let surfaceRaised = Color(hex: "#232327")
    /// Hairline separators.
    static let separator = Color.white.opacity(0.08)

    // MARK: - Text

    static let textPrimary = Color(hex: "#ececec")
    static let textSecondary = Color(hex: "#9a9aa0")
    static let textTertiary = Color(hex: "#6c6c72")

    // MARK: - Accent

    /// A single muted accent (desaturated slate-blue). Used sparingly.
    static let accent = Color(hex: "#5b7a9d")

    // MARK: - Answer-button semantics

    /// Slightly muted versions of the canonical Anki button colors.
    enum Answer {
        static let again = Color(hex: "#c0563f")
        static let hard = Color(hex: "#c07a35")
        static let good = Color(hex: "#4f9d6b")
        static let easy = Color(hex: "#3f7fa6")
    }

    // MARK: - Count badges (deck list)

    enum Count {
        static let new = Color(hex: "#5b7a9d")
        static let learning = Color(hex: "#c0563f")
        static let review = Color(hex: "#4f9d6b")
    }

    // MARK: - Metrics

    static let corner: CGFloat = 12
    static let rowSpacing: CGFloat = 8
}

extension ReviewEase {
    var color: Color {
        switch self {
        case .again: return Theme.Answer.again
        case .hard: return Theme.Answer.hard
        case .good: return Theme.Answer.good
        case .easy: return Theme.Answer.easy
        }
    }

    var label: String {
        switch self {
        case .again: return "もう一度"
        case .hard: return "むずかしい"
        case .good: return "ふつう"
        case .easy: return "かんたん"
        }
    }
}
