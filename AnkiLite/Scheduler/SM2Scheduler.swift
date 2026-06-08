import Foundation

/// Configuration for the SM-2 scheduler. Defaults mirror Anki's out-of-the-box
/// behaviour described in the spec.
struct SchedulerConfig {
    /// Learning steps in minutes (new cards).
    var learningStepsMinutes: [Int] = [1, 10]
    /// Relearning steps in minutes (lapsed review cards).
    var relearningStepsMinutes: [Int] = [10]
    /// Interval (days) when graduating from learning via Good.
    var graduatingIntervalDays: Int = 1
    /// Interval (days) when graduating from learning via Easy.
    var easyIntervalDays: Int = 4
    var startingEase: Double = 2.5
    var minEase: Double = 1.3
    /// Multiplier applied for Easy on review cards.
    var easyBonus: Double = 1.3
    /// Multiplier applied for Hard on review cards.
    var hardMultiplier: Double = 1.2
    /// Global interval modifier.
    var intervalModifier: Double = 1.0
    var maximumIntervalDays: Int = 36500
    /// Whether to apply random fuzz to intervals.
    var enableFuzz: Bool = true
    /// Hour of day (0-23) at which a new day begins. Default 4am.
    var rolloverHour: Int = 4

    static let `default` = SchedulerConfig()
}

/// The outcome of answering a card.
struct ScheduleResult {
    var card: Card
    var log: ReviewLog
}

/// Implements the SM-2 spaced repetition algorithm with Anki-style learning
/// steps, as specified.
struct SM2Scheduler {

    var config: SchedulerConfig
    /// Fuzz function: given an interval in days, returns the fuzzed interval.
    /// Injected for deterministic tests; defaults to random fuzz.
    var fuzz: (Int) -> Int

    init(config: SchedulerConfig = .default) {
        self.config = config
        let cfg = config
        self.fuzz = { interval in
            guard cfg.enableFuzz, interval >= 2 else { return interval }
            let delta = max(1, Int((Double(interval) * 0.05).rounded()))
            return interval + Int.random(in: -delta...delta)
        }
    }

    private let secondsPerDay: Int64 = 86_400
    private let secondsPerMinute: Int64 = 60

    // MARK: - Day arithmetic

    /// The current day number relative to the collection creation time,
    /// honouring the configured rollover hour.
    func today(now: Date, crt: Int64) -> Int {
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let rolloverOffset = Int64(config.rolloverHour) * 3600
        let elapsed = (nowSeconds - rolloverOffset) - crt
        return Int(elapsed / secondsPerDay)
    }

    // MARK: - Answering

    /// Applies an answer to a card, returning the updated card and a review log.
    func answer(card input: Card,
                ease: ReviewEase,
                now: Date = Date(),
                crt: Int64,
                timeTakenMs: Int = 0) -> ScheduleResult {
        var card = input
        let previousIvl = card.ivl
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        switch card.cardType {
        case .new, .learning:
            applyLearning(&card, ease: ease, now: now, crt: crt, steps: config.learningStepsMinutes, isRelearn: false)
        case .relearning:
            applyLearning(&card, ease: ease, now: now, crt: crt, steps: config.relearningStepsMinutes, isRelearn: true)
        case .review:
            applyReview(&card, ease: ease, now: now, crt: crt)
        }

        card.reps += 1
        card.mod = Int64(now.timeIntervalSince1970)

        let log = ReviewLog(
            id: nowMs,
            cid: card.id,
            ease: ease.rawValue,
            ivl: card.ivl,
            lastIvl: previousIvl,
            factor: card.factor,
            time: timeTakenMs,
            type: card.cardType == .review ? 1 : (card.cardType == .relearning ? 2 : 0)
        )

        return ScheduleResult(card: card, log: log)
    }

    // MARK: - Learning / relearning

    /// `left` is reused as "number of steps already completed".
    private func applyLearning(_ card: inout Card,
                               ease: ReviewEase,
                               now: Date,
                               crt: Int64,
                               steps: [Int],
                               isRelearn: Bool) {
        let stepCount = max(steps.count, 1)
        // Sanitize: legitimate values are 0…stepCount (where stepCount means
        // "all steps shown, the next Good graduates"). Anything outside that
        // range — notably Anki's foreign `left` encoding on imported cards
        // (e.g. 1003) — gets reset so we don't accidentally skip ahead.
        var completed = (card.left >= 0 && card.left <= stepCount) ? card.left : 0

        switch ease {
        case .again:
            completed = 0
            scheduleLearningStep(&card, stepMinutes: steps.first ?? 1, now: now, completed: completed, isRelearn: isRelearn)

        case .hard:
            // Repeat the current step.
            let index = min(completed, stepCount - 1)
            scheduleLearningStep(&card, stepMinutes: steps[index], now: now, completed: completed, isRelearn: isRelearn)

        case .good:
            if completed >= stepCount {
                // All steps already shown → graduate to review.
                graduate(&card, now: now, crt: crt, easy: false, isRelearn: isRelearn)
            } else {
                // Schedule the current step's delay and advance the counter.
                let stepMinutes = steps[completed]
                completed += 1
                scheduleLearningStep(&card, stepMinutes: stepMinutes, now: now, completed: completed, isRelearn: isRelearn)
            }

        case .easy:
            graduate(&card, now: now, crt: crt, easy: true, isRelearn: isRelearn)
        }
    }

    private func scheduleLearningStep(_ card: inout Card,
                                      stepMinutes: Int,
                                      now: Date,
                                      completed: Int,
                                      isRelearn: Bool) {
        card.cardType = isRelearn ? .relearning : .learning
        card.cardQueue = .learning
        card.left = completed
        let dueTime = Int64(now.timeIntervalSince1970) + Int64(stepMinutes) * secondsPerMinute
        card.due = dueTime
    }

    private func graduate(_ card: inout Card, now: Date, crt: Int64, easy: Bool, isRelearn: Bool) {
        card.cardType = .review
        card.cardQueue = .review
        card.left = 0

        let interval: Int
        if isRelearn {
            // Return to review at the (reduced) interval set at lapse time.
            interval = max(1, card.ivl)
        } else if easy {
            interval = config.easyIntervalDays
        } else {
            interval = config.graduatingIntervalDays
        }

        let fuzzed = applyConstraints(fuzz(interval))
        card.ivl = fuzzed
        card.due = Int64(today(now: now, crt: crt) + fuzzed)
        if card.factor == 0 { card.easeFactor = config.startingEase }
    }

    // MARK: - Review

    private func applyReview(_ card: inout Card, ease: ReviewEase, now: Date, crt: Int64) {
        let prevIvl = max(card.ivl, 1)
        var newEase = card.easeFactor

        switch ease {
        case .again:
            // Lapse → relearning.
            newEase = max(config.minEase, newEase - 0.20)
            card.easeFactor = newEase
            card.lapses += 1
            card.ivl = 1 // reset interval to 1 day on lapse
            card.cardType = .relearning
            card.cardQueue = .learning
            card.left = 0
            let stepMinutes = config.relearningStepsMinutes.first ?? 10
            card.due = Int64(now.timeIntervalSince1970) + Int64(stepMinutes) * secondsPerMinute
            return

        case .hard:
            newEase = max(config.minEase, newEase - 0.15)
            let ivl = Double(prevIvl) * config.hardMultiplier * config.intervalModifier
            card.ivl = applyConstraints(fuzz(nextInterval(ivl, atLeast: prevIvl + 1)))

        case .good:
            let ivl = Double(prevIvl) * newEase * config.intervalModifier
            card.ivl = applyConstraints(fuzz(nextInterval(ivl, atLeast: prevIvl + 1)))

        case .easy:
            let ivl = Double(prevIvl) * newEase * config.easyBonus * config.intervalModifier
            card.ivl = applyConstraints(fuzz(nextInterval(ivl, atLeast: prevIvl + 1)))
            newEase += 0.15
        }

        card.easeFactor = max(config.minEase, newEase)
        card.cardType = .review
        card.cardQueue = .review
        card.due = Int64(today(now: now, crt: crt) + card.ivl)
    }

    private func nextInterval(_ raw: Double, atLeast minimum: Int) -> Int {
        max(minimum, Int(raw.rounded()))
    }

    private func applyConstraints(_ interval: Int) -> Int {
        min(max(1, interval), config.maximumIntervalDays)
    }

    // MARK: - Button previews

    /// Returns a human-readable next-interval label for each button,
    /// computed without mutating the card or applying fuzz.
    func previewIntervals(for card: Card) -> [ReviewEase: String] {
        var result: [ReviewEase: String] = [:]
        for ease in ReviewEase.allCases {
            result[ease] = previewLabel(for: card, ease: ease)
        }
        return result
    }

    /// Seconds until the next review for a given button (for the preview labels).
    func previewSeconds(for card: Card, ease: ReviewEase) -> Double {
        switch card.cardType {
        case .new, .learning, .relearning:
            let steps = card.cardType == .relearning ? config.relearningStepsMinutes : config.learningStepsMinutes
            let stepCount = max(steps.count, 1)
            switch ease {
            case .again:
                return Double((steps.first ?? 1) * 60)
            case .hard:
                let index = min(card.left, stepCount - 1)
                return Double(steps[index] * 60)
            case .good:
                // Mirrors `applyLearning`: graduate once all steps are shown,
                // otherwise schedule the current step's delay.
                if card.left >= stepCount {
                    return Double(config.graduatingIntervalDays) * 86400
                }
                return Double(steps[card.left] * 60)
            case .easy:
                return Double(config.easyIntervalDays) * 86400
            }
        case .review:
            let prevIvl = Double(max(card.ivl, 1))
            let ef = card.easeFactor
            let days: Double
            switch ease {
            case .again: days = 1
            case .hard: days = max(prevIvl + 1, prevIvl * config.hardMultiplier * config.intervalModifier)
            case .good: days = max(prevIvl + 1, prevIvl * ef * config.intervalModifier)
            case .easy: days = max(prevIvl + 1, prevIvl * ef * config.easyBonus * config.intervalModifier)
            }
            return days * 86400
        }
    }

    private func previewLabel(for card: Card, ease: ReviewEase) -> String {
        formatInterval(seconds: previewSeconds(for: card, ease: ease))
    }

    /// Formats a duration into a compact human label ("< 1分", "10分", "1日", "3か月"…).
    func formatInterval(seconds: Double) -> String {
        if seconds < 60 {
            return "< 1分"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(Int(minutes.rounded()))分"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(Int(hours.rounded()))時間"
        }
        let days = hours / 24
        if days < 30 {
            return "\(Int(days.rounded()))日"
        }
        let months = days / 30
        if months < 12 {
            return "\(Int(months.rounded()))か月"
        }
        let years = days / 365
        return String(format: "%.1f年", years)
    }
}
