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

    init() {
        let defaults = UserDefaults.standard
        self.appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        self.rolloverHour = defaults.object(forKey: Keys.rolloverHour) as? Int ?? 4
        self.newCardsPerDay = defaults.object(forKey: Keys.newCardsPerDay) as? Int ?? 20
    }

    var schedulerConfig: SchedulerConfig {
        var config = SchedulerConfig.default
        config.rolloverHour = rolloverHour
        return config
    }
}
