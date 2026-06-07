import SwiftUI
import Combine

/// User-facing appearance preference.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "システムに従う"
        case .light: return "ライト"
        case .dark: return "ダーク"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide settings, persisted in `UserDefaults`.
final class AppSettings: ObservableObject {
    private enum Keys {
        static let appearance = "appearance"
        static let rolloverHour = "rolloverHour"
        static let newCardsPerDay = "newCardsPerDay"
        static let reviewsPerDay = "reviewsPerDay"
        static let cardFontSize = "cardFontSize"
        static let haptics = "haptics"
    }

    /// Default appearance is dark, per spec.
    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Hour the day rolls over (default 4am).
    @Published var rolloverHour: Int {
        didSet { UserDefaults.standard.set(rolloverHour, forKey: Keys.rolloverHour) }
    }

    @Published var newCardsPerDay: Int {
        didSet { UserDefaults.standard.set(newCardsPerDay, forKey: Keys.newCardsPerDay) }
    }

    /// Daily review cap (0 = unlimited).
    @Published var reviewsPerDay: Int {
        didSet { UserDefaults.standard.set(reviewsPerDay, forKey: Keys.reviewsPerDay) }
    }

    /// Base font size (in px) used by the card WebView.
    @Published var cardFontSize: Int {
        didSet { UserDefaults.standard.set(cardFontSize, forKey: Keys.cardFontSize) }
    }

    /// Whether to play haptic feedback on key actions.
    @Published var haptics: Bool {
        didSet { UserDefaults.standard.set(haptics, forKey: Keys.haptics) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        self.rolloverHour = defaults.object(forKey: Keys.rolloverHour) as? Int ?? 4
        self.newCardsPerDay = defaults.object(forKey: Keys.newCardsPerDay) as? Int ?? 20
        self.reviewsPerDay = defaults.object(forKey: Keys.reviewsPerDay) as? Int ?? 200
        self.cardFontSize = defaults.object(forKey: Keys.cardFontSize) as? Int ?? 22
        self.haptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
    }

    var schedulerConfig: SchedulerConfig {
        var config = SchedulerConfig.default
        config.rolloverHour = rolloverHour
        return config
    }
}
