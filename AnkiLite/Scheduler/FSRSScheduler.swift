import Foundation

/// A simplified FSRS (Free Spaced Repetition Scheduler) — v4.5 weights with
/// the published formulas, surfaced through the same `ScheduleResult` shape
/// our existing UI consumes.
///
/// This is not a drop-in replacement for the full Anki implementation
/// (no fuzz scheduling per state machine; no separate learning steps), but
/// it produces sensible intervals and demonstrably outperforms SM-2 in
/// practice when the user supplies honest ratings.
struct FSRSScheduler {

    /// FSRS-4.5 default weights (Open Spaced Repetition project).
    static let defaultWeights: [Double] = [
        0.4072, 1.1829, 3.1262, 15.4722, 7.2102, 0.5316, 1.0651, 0.0234,
        1.616, 0.1544, 1.0824, 1.9813, 0.0953, 0.2975, 2.2042, 0.2407,
        2.9466, 0.5034, 0.6567
    ]

    var w: [Double] = FSRSScheduler.defaultWeights
    /// Desired retention (probability the card is recalled at review time).
    var desiredRetention: Double = 0.9
    var maximumInterval: Double = 36500
    var minimumInterval: Double = 1

    // MARK: - Helpers

    /// Days between two unix-second timestamps (≥ 0).
    private func elapsedDays(from last: Int64, to now: Int64) -> Double {
        guard last > 0 else { return 0 }
        return max(0, Double(now - last) / 86_400.0)
    }

    /// FSRS retrievability after `t` days for a card with stability `s`.
    func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(1 + t / (9 * s), -1)
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    /// Initial stability for the first review (rating ∈ 1...4).
    private func initialStability(rating: Int) -> Double {
        max(w[rating - 1], 0.1)
    }

    /// Initial difficulty for the first review.
    private func initialDifficulty(rating: Int) -> Double {
        clamp(w[4] - exp(w[5] * Double(rating - 1)) + 1, 1, 10)
    }

    /// Updated difficulty after a non-first review.
    private func nextDifficulty(d: Double, rating: Int) -> Double {
        let deltaD = -w[6] * Double(rating - 3)
        // Mean-revert toward the initial Good-rating difficulty.
        let dInitGood = initialDifficulty(rating: 3)
        let dPrime = d + deltaD * ((10 - d) / 9)
        let dRev = w[7] * dInitGood + (1 - w[7]) * dPrime
        return clamp(dRev, 1, 10)
    }

    /// Updated stability after a successful review (Hard/Good/Easy).
    private func successStability(d: Double, s: Double, r: Double, rating: Int) -> Double {
        let hardPenalty = rating == 2 ? w[15] : 1.0
        let easyBonus = rating == 4 ? w[16] : 1.0
        let alpha = exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1)
        return s * (1 + alpha * hardPenalty * easyBonus)
    }

    /// Updated stability after a failure (rating 1 / Again).
    private func failStability(d: Double, s: Double, r: Double) -> Double {
        let factor = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
        return max(0.1, factor)
    }

    /// Interval (in days) such that retrievability at that point equals
    /// `desiredRetention`.
    private func nextInterval(stability s: Double) -> Int {
        let raw = 9 * s * (1 / desiredRetention - 1)
        return Int(clamp(raw.rounded(), minimumInterval, maximumInterval))
    }

    // MARK: - Public answer entry point

    /// Apply an answer to a card, returning the updated card + review log.
    ///
    /// New and learning cards go through the standard learning steps first
    /// (this matches Anki's behaviour: FSRS only governs review intervals,
    /// not the initial learning sequence). At graduation we seed the FSRS
    /// memory state and switch the card to a FSRS-driven interval.
    func answer(card input: Card,
                ease: ReviewEase,
                now: Date = Date(),
                crt: Int64,
                timeTakenMs: Int = 0) -> ScheduleResult {
        // Route new/learning/relearning cards through SM-2's learning step
        // machinery first; only graduated cards run through FSRS proper.
        if input.cardType == .new || input.cardType == .learning || input.cardType == .relearning {
            return learningPath(card: input, ease: ease, now: now, crt: crt, timeTakenMs: timeTakenMs)
        }
        return reviewPath(card: input, ease: ease, now: now, crt: crt, timeTakenMs: timeTakenMs)
    }

    /// Drives the learning/relearning portion using SM-2's step logic, then
    /// reaches into FSRS to (re)initialise the memory state on graduation.
    private func learningPath(card input: Card,
                              ease: ReviewEase,
                              now: Date,
                              crt: Int64,
                              timeTakenMs: Int) -> ScheduleResult {
        let sm2 = SM2Scheduler()
        var result = sm2.answer(card: input,
                                ease: ease,
                                now: now,
                                crt: crt,
                                timeTakenMs: timeTakenMs)

        let nowSec = Int64(now.timeIntervalSince1970)
        let rating = ease.rawValue

        if result.card.cardType == .review {
            // Graduated by SM-2; seed FSRS memory and override the interval
            // so the next review is FSRS-driven rather than the SM-2 flat 1 day.
            let s = initialStability(rating: rating)
            let d = initialDifficulty(rating: rating)
            result.card.stability = s
            result.card.difficulty = d
            result.card.lastReview = nowSec

            let interval = nextInterval(stability: s)
            result.card.ivl = interval
            let todayDays = Int((nowSec - crt) / 86_400)
            result.card.due = Int64(todayDays + interval)

            result.log.ivl = result.card.ivl
            result.log.factor = Int(s * 1000)
        }
        return result
    }

    /// Standard FSRS update path for cards already in the review queue.
    private func reviewPath(card input: Card,
                            ease: ReviewEase,
                            now: Date,
                            crt: Int64,
                            timeTakenMs: Int) -> ScheduleResult {
        var card = input
        let rating = ease.rawValue
        let nowSec = Int64(now.timeIntervalSince1970)
        let previousIvl = card.ivl

        let isFirstReview = card.stability == 0
        let s: Double
        let d: Double

        if isFirstReview {
            s = initialStability(rating: rating)
            d = initialDifficulty(rating: rating)
        } else {
            let elapsed = elapsedDays(from: card.lastReview, to: nowSec)
            let r = retrievability(elapsedDays: elapsed, stability: card.stability)
            d = nextDifficulty(d: card.difficulty, rating: rating)
            if rating == 1 {
                s = failStability(d: card.difficulty, s: card.stability, r: r)
                card.lapses += 1
            } else {
                s = successStability(d: card.difficulty, s: card.stability, r: r, rating: rating)
            }
        }

        card.stability = s
        card.difficulty = d
        card.lastReview = nowSec
        card.reps += 1
        card.mod = nowSec

        if rating == 1 {
            // Lapse → relearning queue, FSRS memory preserved.
            card.ivl = 1
            card.cardType = .relearning
            card.cardQueue = .learning
            card.left = 0
            card.due = nowSec + 600
        } else {
            let interval = nextInterval(stability: s)
            card.ivl = interval
            card.cardType = .review
            card.cardQueue = .review
            let todayDays = Int((nowSec - crt) / 86_400)
            card.due = Int64(todayDays + interval)
        }

        let logId = Int64(now.timeIntervalSince1970 * 1000)
        let log = ReviewLog(
            id: logId,
            cid: card.id,
            ease: rating,
            ivl: card.ivl,
            lastIvl: previousIvl,
            factor: Int(s * 1000),
            time: timeTakenMs,
            type: rating == 1 ? 2 : 1  // 2 = relearn, 1 = review
        )
        return ScheduleResult(card: card, log: log)
    }

    // MARK: - Preview labels for buttons

    /// Estimated next-review interval label per button (without mutating the card).
    func previewIntervals(for card: Card) -> [ReviewEase: String] {
        var out: [ReviewEase: String] = [:]
        for ease in ReviewEase.allCases {
            out[ease] = previewLabel(for: card, ease: ease)
        }
        return out
    }

    private func previewLabel(for card: Card, ease: ReviewEase) -> String {
        // New/learning/relearning previews defer to SM-2's step labels so the
        // bottom button row matches what answering will actually do.
        if card.cardType == .new || card.cardType == .learning || card.cardType == .relearning {
            return SM2Scheduler().previewIntervals(for: card)[ease] ?? ""
        }

        let rating = ease.rawValue
        let isFirst = card.stability == 0
        let s: Double
        if isFirst {
            s = initialStability(rating: rating)
        } else {
            let elapsed = elapsedDays(from: card.lastReview, to: Int64(Date().timeIntervalSince1970))
            let r = retrievability(elapsedDays: elapsed, stability: card.stability)
            if rating == 1 {
                s = failStability(d: card.difficulty, s: card.stability, r: r)
            } else {
                s = successStability(d: card.difficulty, s: card.stability, r: r, rating: rating)
            }
        }
        if rating == 1 { return "< 10分" }
        let days = nextInterval(stability: s)
        return SM2Scheduler().formatInterval(seconds: Double(days) * 86400)
    }
}
