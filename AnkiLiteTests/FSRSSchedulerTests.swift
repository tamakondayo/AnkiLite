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
                       "First Good on new card must stay in learning queue")
        XCTAssertEqual(result.card.cardQueue, .learning)
        // Should be ~1 minute away, not 3 days.
        let expected = Int64(now.timeIntervalSince1970) + 60
        XCTAssertEqual(result.card.due, expected,
                       "First Good should schedule the 1-minute learning step")
        XCTAssertEqual(result.card.stability, 0,
                       "FSRS memory state must NOT be seeded until graduation")
    }

    /// After two Goods (passing through the [1m, 10m] steps), a third Good
    /// graduates the card and FSRS takes over the interval calculation.
    func testThirdGoodGraduatesAndSeedsFSRS() {
        let scheduler = makeScheduler()
        var card = newCard()
        card = scheduler.answer(card: card, ease: .good, crt: 0).card  // step 1
        card = scheduler.answer(card: card, ease: .good, crt: 0).card  // step 2
        card = scheduler.answer(card: card, ease: .good, crt: 0).card  // graduate

        XCTAssertEqual(card.cardType, .review,
                       "Card should graduate to review after all learning steps")
        XCTAssertGreaterThan(card.stability, 0,
                             "FSRS memory state must be seeded on graduation")
        XCTAssertGreaterThanOrEqual(card.ivl, 1)
    }

    func testNewCardAgainStaysAtFirstStep() {
        let scheduler = makeScheduler()
        let result = scheduler.answer(card: newCard(), ease: .again, crt: 0)
        XCTAssertEqual(result.card.cardType, .learning)
        XCTAssertEqual(result.card.left, 0)
        XCTAssertEqual(result.card.stability, 0)
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
