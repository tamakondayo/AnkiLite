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
}

/// Which scheduling algorithm to use.
enum SchedulerKind: String, CaseIterable, Identifiable {
    case sm2 = "sm2"
    case fsrs = "fsrs"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sm2: return "SM-2 (互換)"
        case .fsrs: return "FSRS (新方式)"
        }
    }

    var subtitle: String {
        switch self {
        case .sm2: return "Anki 互換のクラシック方式"
        case .fsrs: return "Anki 23.10+ の既定。新しい統計的アルゴリズム"
        }
    }
}

// MARK: - Conformance

extension SM2Scheduler: CardScheduler {}

extension FSRSScheduler: CardScheduler {
    /// FSRS does not have a rollover concept of its own; defer to SM-2's
    /// implementation so day-number calculations stay consistent.
    func today(now: Date, crt: Int64) -> Int {
        SM2Scheduler().today(now: now, crt: crt)
    }
}
