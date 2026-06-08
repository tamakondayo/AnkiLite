import XCTest
@testable import AnkiLite

final class SM2SchedulerTests: XCTestCase {

    /// A scheduler with fuzz disabled for deterministic interval assertions.
    private func makeScheduler() -> SM2Scheduler {
        var config = SchedulerConfig.default
        config.enableFuzz = false
        return SM2Scheduler(config: config)
    }

    private func newCard() -> Card {
        Card(id: 1, nid: 1, did: 1, ord: 0, type: CardType.new.rawValue,
             queue: CardQueue.new.rawValue, due: 0, ivl: 0, factor: 2500)
    }

    private func reviewCard(ivl: Int, factor: Int = 2500) -> Card {
        Card(id: 1, nid: 1, did: 1, ord: 0, type: CardType.review.rawValue,
             queue: CardQueue.review.rawValue, due: 0, ivl: ivl, factor: factor)
    }

    // MARK: - Learning

    func testNewCardGoodEntersLearning() {
        let scheduler = makeScheduler()
        let now = Date()
        let result = scheduler.answer(card: newCard(), ease: .good, now: now, crt: 0)
        XCTAssertEqual(result.card.cardType, .learning)
        XCTAssertEqual(result.card.cardQueue, .learning)
        XCTAssertEqual(result.card.reps, 1)
        // First Good should schedule the next view at the first step (1 minute),
        // NOT graduate to a 1-day review.
        let expected = Int64(now.timeIntervalSince1970) + 60
        XCTAssertEqual(result.card.due, expected,
                       "First Good on a new card must wait ~1 minute, not graduate")
        XCTAssertEqual(result.card.ivl, 0)
    }

    func testNewCardAgainStaysAtFirstStep() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: newCard(), ease: .again, crt: 0)
        XCTAssertEqual(result.card.cardType, .learning)
        XCTAssertEqual(result.card.left, 0)
    }

    func testNewCardEasyGraduatesImmediately() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: newCard(), ease: .easy, crt: 0)
        XCTAssertEqual(result.card.cardType, .review)
        XCTAssertEqual(result.card.ivl, SchedulerConfig.default.easyIntervalDays)
    }

    func testNewCardHardIsDistinctFromGood() {
        // With default steps [1m, 10m], Hard on a new card should be the
        // average of step 0 (1m) and step 1 (10m) ≈ 6m — not just 1m
        // like Good. Otherwise the user sees identical labels on Hard
        // and Good which makes the buttons feel broken.
        let scheduler = makeScheduler()
        let now = Date()
        let result = scheduler.answer(card: newCard(), ease: .hard, now: now, crt: 0)

        let expected = Int64(now.timeIntervalSince1970) + 6 * 60
        XCTAssertEqual(result.card.due, expected,
                       "Hard on a new card should be ~6 minutes (mid-step), not 1")
        XCTAssertEqual(result.card.cardType, .learning)
    }

    func testNewCardOutOfRangeLeftDoesNotGraduate() {
        // Regression: cards imported from .apkg use Anki's `left` encoding,
        // which would otherwise be interpreted as "completed steps" and
        // immediately graduate the card. The scheduler must sanitize this.
        let scheduler = makeScheduler()
        var card = newCard()
        card.left = 1003 // Anki "1 step remaining, 3 reps today"

        let result = scheduler.answer(card: card, ease: .good, crt: 0)
        XCTAssertEqual(result.card.cardType, .learning,
                       "Sanitized left must not cause immediate graduation")
        XCTAssertEqual(result.card.ivl, 0)
    }

    func testLearningGraduatesAfterAllSteps() {
        let scheduler = makeScheduler()
        // Default steps [1, 10] → three Good presses to graduate.
        var card = newCard()
        card = scheduler.answer(card: card, ease: .good, crt: 0).card // step 1
        XCTAssertEqual(card.cardType, .learning)
        card = scheduler.answer(card: card, ease: .good, crt: 0).card // step 2
        XCTAssertEqual(card.cardType, .learning)
        card = scheduler.answer(card: card, ease: .good, crt: 0).card // graduate
        XCTAssertEqual(card.cardType, .review)
        XCTAssertEqual(card.ivl, SchedulerConfig.default.graduatingIntervalDays)
    }

    // MARK: - Review

    func testReviewGoodMultipliesByEase() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: reviewCard(ivl: 10, factor: 2500), ease: .good, crt: 0)
        // 10 * 2.5 = 25
        XCTAssertEqual(result.card.ivl, 25)
        XCTAssertEqual(result.card.factor, 2500) // ease unchanged on Good
        XCTAssertEqual(result.card.cardType, .review)
    }

    func testReviewHardUsesHardMultiplierAndLowersEase() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: reviewCard(ivl: 10, factor: 2500), ease: .hard, crt: 0)
        // 10 * 1.2 = 12
        XCTAssertEqual(result.card.ivl, 12)
        // ease 2.5 - 0.15 = 2.35
        XCTAssertEqual(result.card.factor, 2350)
    }

    func testReviewEasyAddsBonusAndRaisesEase() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: reviewCard(ivl: 10, factor: 2500), ease: .easy, crt: 0)
        // 10 * 2.5 * 1.3 = 32.5 → 33
        XCTAssertEqual(result.card.ivl, 33)
        // ease 2.5 + 0.15 = 2.65
        XCTAssertEqual(result.card.factor, 2650)
    }

    func testReviewAgainLapsesAndEntersRelearning() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: reviewCard(ivl: 20, factor: 2500), ease: .again, crt: 0)
        XCTAssertEqual(result.card.cardType, .relearning)
        XCTAssertEqual(result.card.lapses, 1)
        XCTAssertEqual(result.card.ivl, 1)            // reset to 1 day
        XCTAssertEqual(result.card.factor, 2300)      // 2.5 - 0.20
    }

    func testEaseFactorFloor() {
        let scheduler = makeScheduler()
        // Start near the floor; Again should not drop below 1.30.
        let result = scheduler.answer(card: reviewCard(ivl: 5, factor: 1400), ease: .again, crt: 0)
        XCTAssertEqual(result.card.factor, 1300)
    }

    // MARK: - Interval formatting

    func testIntervalFormatting() {
        let scheduler = makeScheduler()
        XCTAssertEqual(scheduler.formatInterval(seconds: 30), "< 1分")
        XCTAssertEqual(scheduler.formatInterval(seconds: 600), "10分")
        XCTAssertEqual(scheduler.formatInterval(seconds: 86400), "1日")
        XCTAssertEqual(scheduler.formatInterval(seconds: 86400 * 3), "3日")
    }

    // MARK: - Review log

    func testReviewLogRecorded() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: reviewCard(ivl: 10), ease: .good, crt: 0, timeTakenMs: 1500)
        XCTAssertEqual(result.log.ease, ReviewEase.good.rawValue)
        XCTAssertEqual(result.log.lastIvl, 10)
        XCTAssertEqual(result.log.ivl, result.card.ivl)
        XCTAssertEqual(result.log.time, 1500)
    }
}
