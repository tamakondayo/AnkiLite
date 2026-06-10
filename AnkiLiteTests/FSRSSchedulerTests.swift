import XCTest
@testable import AnkiLite

final class FSRSSchedulerTests: XCTestCase {

    private func makeScheduler() -> FSRSScheduler { FSRSScheduler() }

    private func newCard() -> Card {
        Card(id: 1, nid: 1, did: 1, ord: 0,
             type: CardType.new.rawValue,
             queue: CardQueue.new.rawValue,
             due: 0, ivl: 0, factor: 2500)
    }

    // MARK: - Learning steps

    /// New cards should go through learning steps (1m / 10m), NOT jump
    /// straight to a multi-day FSRS interval on the first Good.
    func testNewCardGoodEntersLearningNotReview() {
        let scheduler = makeScheduler()
        let now = Date()
        let result = scheduler.answer(card: newCard(), ease: .good, now: now, crt: 0)

        XCTAssertEqual(result.card.cardType, .learning,
                       "First Good on a new card must stay in learning queue")
        XCTAssertEqual(result.card.cardQueue, .learning)
        // Matches Anki upstream: first Good advances to the next step (10m).
        let expected = Int64(now.timeIntervalSince1970) + 10 * 60
        XCTAssertEqual(result.card.due, expected,
                       "First Good should schedule the NEXT learning step (10m)")
        // fsrs-rs `step`: the first-ever answer seeds the memory state
        // (init_stability(Good) == w[2]), even while still in learning.
        XCTAssertEqual(result.card.stability, 2.3065, accuracy: 0.0001,
                       "First answer must seed the FSRS memory state")
    }

    /// Two Goods (advance to step 1, then graduate) hand off to FSRS.
    func testSecondGoodGraduatesAndSeedsFSRS() {
        let scheduler = makeScheduler()
        var card = newCard()
        card = scheduler.answer(card: card, ease: .good, crt: 0).card  // → step 1
        card = scheduler.answer(card: card, ease: .good, crt: 0).card  // → graduate

        XCTAssertEqual(card.cardType, .review,
                       "Card should graduate to review after all learning steps")
        // Short-term sinc for Good is clamped to ≥ 1, so stability can only
        // have grown from the seeded w[2].
        XCTAssertGreaterThanOrEqual(card.stability, 2.3065 - 0.0001)
        XCTAssertGreaterThanOrEqual(card.ivl, 1)
    }

    func testNewCardAgainStaysAtFirstStep() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: newCard(), ease: .again, crt: 0)
        XCTAssertEqual(result.card.cardType, .learning)
        XCTAssertEqual(result.card.left, 0)
        // init_stability(Again) == w[0].
        XCTAssertEqual(result.card.stability, 0.212, accuracy: 0.0001)
    }

    /// Same-day Again after a seeded state shrinks stability via the
    /// short-term curve (sinc < 1 allowed for rating 1).
    func testShortTermAgainShrinksStability() {
        let scheduler = makeScheduler()
        var card = newCard()
        card = scheduler.answer(card: card, ease: .good, crt: 0).card   // seed 2.3065
        let before = card.stability
        card = scheduler.answer(card: card, ease: .again, crt: 0).card  // short-term Again
        XCTAssertLessThan(card.stability, before,
                          "Again during learning should reduce stability")
        XCTAssertGreaterThan(card.stability, 0)
    }

    // MARK: - Numerical conformance with fsrs-rs (FSRS-6 defaults)

    /// `init_stability(Good) == w[2] == 2.3065`.
    func testInitStabilityMatchesUpstreamWeights() {
        let scheduler = makeScheduler()
        // First Good on a fresh review card seeds stability from w[2].
        var card = newCard()
        card.cardType = .review
        card.cardQueue = .review
        let result = scheduler.answer(card: card, ease: .good, crt: 0)
        XCTAssertEqual(result.card.stability, 2.3065, accuracy: 0.0001)
    }

    /// At desired retention 0.9 the first interval from `s ≈ 2.31` is ~2 days
    /// (FSRS-6 default decay 0.1542).
    func testFirstReviewIntervalAroundExpectedDays() {
        let scheduler = makeScheduler()
        var card = newCard()
        card.cardType = .review
        card.cardQueue = .review
        let result = scheduler.answer(card: card, ease: .good, crt: 0)
        // Hand-computed: 2.3065 / 0.9795 * (1.9796 - 1) ≈ 2.31 → rounded → 2
        XCTAssertEqual(result.card.ivl, 2)
    }

    /// FSRS-6 forgetting curve: at s = t = 5 days, retrievability ≈ 0.879.
    /// (Hand-computed: (5/5 * 0.9795 + 1)^(-0.1542) ≈ 0.900.)
    func testForgettingCurveAtUnitTime() {
        let scheduler = makeScheduler()
        let r = scheduler.retrievability(elapsedDays: 5, stability: 5)
        XCTAssertEqual(r, 0.9, accuracy: 0.01)
    }

    /// Higher difficulty → smaller stability growth on Good than lower difficulty.
    func testDifficultyReducesStabilityGrowth() {
        let scheduler = makeScheduler()
        var easy = newCard()
        easy.cardType = .review; easy.cardQueue = .review
        easy.stability = 10; easy.difficulty = 2
        easy.lastReview = Int64(Date().timeIntervalSince1970) - 10 * 86_400

        var hard = newCard()
        hard.cardType = .review; hard.cardQueue = .review
        hard.stability = 10; hard.difficulty = 8
        hard.lastReview = Int64(Date().timeIntervalSince1970) - 10 * 86_400

        let easyResult = scheduler.answer(card: easy, ease: .good, crt: 0)
        let hardResult = scheduler.answer(card: hard, ease: .good, crt: 0)

        XCTAssertGreaterThan(easyResult.card.stability, hardResult.card.stability,
                             "Easier cards (low difficulty) should grow more on Good")
    }

    func testReviewCardGoodUsesFSRSStabilityUpdate() {
        let scheduler = makeScheduler()
        // Manually seeded review card (already graduated).
        var card = newCard()
        card.cardType = .review
        card.cardQueue = .review
        card.stability = 5.0
        card.difficulty = 5.0
        card.ivl = 5
        card.lastReview = Int64(Date().timeIntervalSince1970) - 5 * 86_400

        let result = scheduler.answer(card: card, ease: .good, crt: 0)
        XCTAssertEqual(result.card.cardType, .review)
        XCTAssertGreaterThan(result.card.stability, 5.0,
                             "Successful FSRS review should grow stability")
        XCTAssertGreaterThanOrEqual(result.card.ivl, 1)
    }
}
