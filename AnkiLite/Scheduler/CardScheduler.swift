import Foundation

/// Common interface implemented by SM-2 and FSRS so the rest of the app
/// can swap algorithms without caring which is active.
protocol CardScheduler {
    func answer(card: Card,
                ease: ReviewEase,
                now: Date,
                crt: Int64,
                timeTakenMs: Int) -> ScheduleResult

    func previewIntervals(for card: Card) -> [ReviewEase: String]

    /// The current "today" day-number for due-date arithmetic.
    func today(now: Date, crt: Int64) -> Int

    /// Hour of day (0–23) at which the study day rolls over.
    var rolloverHour: Int { get }
}

/// Which scheduling algorithm to use.
enum SchedulerKind: String, CaseIterable, Identifiable {
    case sm2 = "sm2"
    case fsrs = "fsrs"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sm2: return String(localized: "SM-2 (互換)")
        case .fsrs: return String(localized: "FSRS (新方式)")
        }
    }

    var subtitle: String {
        switch self {
        case .sm2: return String(localized: "クラシックな SM-2 方式 (SuperMemo 系)")
        case .fsrs: return String(localized: "新しい統計的アルゴリズム (推奨)")
        }
    }
}

// MARK: - Conformance

extension SM2Scheduler: CardScheduler {
    var rolloverHour: Int { config.rolloverHour }
}

extension FSRSScheduler: CardScheduler {
    /// FSRS does not have a rollover concept of its own; defer to SM-2's
    /// implementation (with our rollover hour) so day-number calculations
    /// stay consistent across both schedulers.
    func today(now: Date, crt: Int64) -> Int {
        SM2Scheduler(config: sm2Config).today(now: now, crt: crt)
    }
}
