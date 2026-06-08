import Foundation

/// FSRS scheduler aligned with **open-spaced-repetition/fsrs-rs** (the
/// upstream Rust implementation Anki itself ships).
///
/// Algorithm version: FSRS-6 (21 parameters, decay parameterised as w[20]).
/// Formulas are quoted from the source comments below so they stay easy to
/// compare with the canonical implementation.
///
/// Learning / relearning steps are still routed through SM-2's step machine
/// (the same way Anki keeps learning steps separate from FSRS memory state).
/// FSRS proper governs review-state cards and the graduation interval.
struct FSRSScheduler {

    /// FSRS-6 default parameters (open-spaced-repetition/fsrs-rs).
    /// Layout:
    /// - w[0..=3]   initial stability for ratings 1..=4 (Again/Hard/Good/Easy)
    /// - w[4..=5]   initial difficulty parameters
    /// - w[6]       difficulty update coefficient (delta_d)
    /// - w[7]       mean-reversion weight
    /// - w[8..=10]  next_recall_stability shape
    /// - w[11..=14] next_forget_stability shape
    /// - w[15]      hard_penalty
    /// - w[16]      easy_bonus
    /// - w[17..=19] short-term stability parameters
    /// - w[20]      decay (positive — used as `-w[20]` in the curve)
    static let defaultWeights: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956,
        6.4133, 0.8334,
        3.0194,
        0.001,
        1.8722, 0.1666, 0.796,
        1.4835, 0.0614, 0.2629, 1.6483,
        0.6014,
        1.8729,
        0.5425, 0.0912, 0.0658,
        0.1542
    ]

    var w: [Double] = FSRSScheduler.defaultWeights
    var desiredRetention: Double = 0.9
    var maximumInterval: Double = 36500
    var minimumInterval: Double = 1

    // MARK: - Curve constants

    /// FSRS-6 forgetting-curve decay. Stored as `-w[20]` so the math reads
    /// like the Rust source (`decay = -w[20]`, factor uses ln/exp).
    private var decay: Double { -w[20] }

    /// Per Rust: `factor = (0.9.ln() / decay).exp() - 1.0`
    private var factor: Double { exp(log(0.9) / decay) - 1.0 }

    // MARK: - Helpers

    /// Retrievability after `t` days for a card with stability `s` (FSRS-6
    /// power forgetting curve):
    ///
    ///     (t / s * factor + 1).powf(decay)
    func retrievability(elapsedDays t: Double, stability s: Double) -> Double {
        guard s > 0 else { return 0 }
        return pow(t / s * factor + 1.0, decay)
    }

    private func elapsedDays(from last: Int64, to now: Int64) -> Double {
        guard last > 0 else { return 0 }
        return max(0, Double(now - last) / 86_400.0)
    }

    private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }

    // MARK: - Memory state updates (mirror fsrs-rs/src/model.rs)

    /// `init_stability = w[rating - 1]` (clamped to ≥ 0.1).
    private func initialStability(rating: Int) -> Double {
        let idx = max(0, min(rating - 1, 3))
        return max(0.1, w[idx])
    }

    /// `init_difficulty = w[4] - exp(w[5] * (rating - 1)) + 1`, clamped to [1,10].
    private func initialDifficulty(rating: Int) -> Double {
        clamp(w[4] - exp(w[5] * Double(rating - 1)) + 1.0, 1, 10)
    }

    /// Linear damping that softens difficulty deltas near the upper bound:
    /// `delta_d * (10 - d) / 9`.
    private func linearDamping(_ deltaD: Double, _ d: Double) -> Double {
        deltaD * (10.0 - d) / 9.0
    }

    /// Mean-reverts toward the initial Easy-rating difficulty:
    /// `w[7] * (init_difficulty(4) - new_d) + new_d`.
    private func meanReversion(_ newD: Double) -> Double {
        w[7] * (initialDifficulty(rating: 4) - newD) + newD
    }

    /// `delta_d = -w[6] * (rating - 3)`, then damped, then mean-reverted.
    private func nextDifficulty(d: Double, rating: Int) -> Double {
        let deltaD = -w[6] * Double(rating - 3)
        let damped = d + linearDamping(deltaD, d)
        return clamp(meanReversion(damped), 1, 10)
    }

    /// On Hard/Good/Easy:
    ///
    ///     last_s * (exp(w[8]) * (11 - d) * last_s.powf(-w[9])
    ///              * ((1 - r) * w[10]).exp() - 1)
    ///              * hard_penalty * easy_bonus + 1)
    private func nextRecallStability(d: Double, s: Double, r: Double, rating: Int) -> Double {
        let hardPenalty = rating == 2 ? w[15] : 1.0
        let easyBonus = rating == 4 ? w[16] : 1.0
        let alpha = exp(w[8]) * (11.0 - d) * pow(s, -w[9]) * (exp((1.0 - r) * w[10]) - 1.0)
        return s * (alpha * hardPenalty * easyBonus + 1.0)
    }

    /// On Again, with an upper clamp `last_s / exp(w[17] * w[18])`:
    ///
    ///     w[11] * d.powf(-w[12]) * ((s + 1).powf(w[13]) - 1)
    ///          * ((1 - r) * w[14]).exp()
    private func nextForgetStability(d: Double, s: Double, r: Double) -> Double {
        let raw = w[11] * pow(d, -w[12]) * (pow(s + 1.0, w[13]) - 1.0) * exp((1.0 - r) * w[14])
        let upper = s / exp(w[17] * w[18])
        return max(0.1, min(raw, upper))
    }

    /// Maps stability → days such that retrievability at that point equals
    /// `desired_retention`:
    ///
    ///     stability / factor * (desired_retention.powf(1.0 / decay) - 1.0)
    private func nextInterval(stability s: Double) -> Int {
        let raw = s / factor * (pow(desiredRetention, 1.0 / decay) - 1.0)
        return Int(clamp(raw.rounded(), minimumInterval, maximumInterval))
    }

    // MARK: - Public answer entry point

    func answer(card input: Card,
                ease: ReviewEase,
                now: Date = Date(),
                crt: Int64,
                timeTakenMs: Int = 0) -> ScheduleResult {
        if input.cardType == .new || input.cardType == .learning || input.cardType == .relearning {
            return learningPath(card: input, ease: ease, now: now, crt: crt, timeTakenMs: timeTakenMs)
        }
        return reviewPath(card: input, ease: ease, now: now, crt: crt, timeTakenMs: timeTakenMs)
    }

    /// Learning / relearning runs through SM-2's step machinery; FSRS
    /// memory state is seeded at graduation.
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
                s = nextForgetStability(d: card.difficulty, s: card.stability, r: r)
                card.lapses += 1
            } else {
                s = nextRecallStability(d: card.difficulty, s: card.stability, r: r, rating: rating)
            }
        }

        card.stability = s
        card.difficulty = d
        card.lastReview = nowSec
        card.reps += 1
        card.mod = nowSec

        if rating == 1 {
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
            type: rating == 1 ? 2 : 1
        )
        return ScheduleResult(card: card, log: log)
    }

    // MARK: - Preview labels

    func previewIntervals(for card: Card) -> [ReviewEase: String] {
        var out: [ReviewEase: String] = [:]
        for ease in ReviewEase.allCases {
            out[ease] = previewLabel(for: card, ease: ease)
        }
        return out
    }

    private func previewLabel(for card: Card, ease: ReviewEase) -> String {
        // Learning previews defer to SM-2 so the button labels match what
        // pressing the button will actually do during learning steps.
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
                s = nextForgetStability(d: card.difficulty, s: card.stability, r: r)
            } else {
                s = nextRecallStability(d: card.difficulty, s: card.stability, r: r, rating: rating)
            }
        }
        if rating == 1 { return "< 10分" }
        let days = nextInterval(stability: s)
        return SM2Scheduler().formatInterval(seconds: Double(days) * 86400)
    }
}
