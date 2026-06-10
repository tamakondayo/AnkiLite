import XCTest
import GRDB
@testable import AnkiLite

@MainActor
final class StudySessionTests: XCTestCase {

    /// Builds an in-memory collection: one deck, one note type, `reviewCount`
    /// review cards due today and `newCount` new cards — no review history
    /// (like a deck imported from a shared apkg).
    private func makeCollection(reviewCount: Int, newCount: Int) throws -> (DatabaseManager, Deck) {
        let db = try DatabaseManager.inMemory()
        // Collection created 90 days ago so review day-numbers are sane.
        try db.setCollectionCreationTime(Int64(Date().timeIntervalSince1970) - 90 * 86_400)

        let deck = Deck(id: 1, name: "Test")
        let noteType = NoteType(
            id: 1, name: "Basic",
            fields: [NoteField(name: "Front", ord: 0), NoteField(name: "Back", ord: 1)],
            templates: [CardTemplate(name: "Card 1", ord: 0,
                                     qfmt: "{{Front}}", afmt: "{{Back}}")],
            css: "", type: 0)

        try db.dbQueue.write { writer in
            try deck.insert(writer)
            try noteType.insert(writer)
            var id: Int64 = 1
            for _ in 0..<reviewCount {
                try Note(id: id, guid: "g\(id)", mid: 1, mod: 0, tags: "",
                         flds: "q\(id)\u{1f}a\(id)", sfld: "q\(id)").insert(writer)
                try Card(id: id, nid: id, did: 1, ord: 0,
                         type: CardType.review.rawValue,
                         queue: CardQueue.review.rawValue,
                         due: 0, ivl: 10, factor: 2500).insert(writer)
                id += 1
            }
            for _ in 0..<newCount {
                try Note(id: id, guid: "g\(id)", mid: 1, mod: 0, tags: "",
                         flds: "q\(id)\u{1f}a\(id)", sfld: "q\(id)").insert(writer)
                try Card(id: id, nid: id, did: 1, ord: 0,
                         type: CardType.new.rawValue,
                         queue: CardQueue.new.rawValue,
                         due: id, ivl: 0, factor: 2500).insert(writer)
                id += 1
            }
        }
        return (db, deck)
    }

    /// Regression: in a deck imported without history, answering review
    /// cards must NOT consume the daily new-card quota. (Their first-ever
    /// local revlog entry is created today, which the previous
    /// "first-review-today" counting treated as a new-card introduction —
    /// ending mixed sessions after exactly `newCardLimit` answers.)
    func testReviewAnswersDoNotConsumeNewCardQuota() throws {
        let (db, deck) = try makeCollection(reviewCount: 3, newCount: 2)
        let session = try StudySession(deck: deck,
                                       database: db,
                                       scheduler: SM2Scheduler(),
                                       newCardLimit: 1,
                                       reviewLimit: 0)

        // The three due review cards come first.
        for i in 0..<3 {
            XCTAssertEqual(session.current?.card.cardType, .review,
                           "Card \(i) should be a review card")
            try session.answer(.good)
        }

        // The new-card quota (1) must still be available.
        XCTAssertFalse(session.isFinished,
                       "Session must not end after the review cards")
        XCTAssertEqual(session.current?.card.cardType, .new,
                       "A new card must still be served after 3 review answers")

        // Introduce it (graduates nothing; goes to a 10-minute learning step),
        // after which the second new card is blocked by the quota.
        try session.answer(.easy)
        XCTAssertTrue(session.isFinished,
                      "Second new card must be blocked by newCardLimit = 1")
    }

    /// New cards answered today DO consume the quota (sanity check).
    func testNewCardIntroductionsConsumeQuota() throws {
        let (db, deck) = try makeCollection(reviewCount: 0, newCount: 3)
        let session = try StudySession(deck: deck,
                                       database: db,
                                       scheduler: SM2Scheduler(),
                                       newCardLimit: 2,
                                       reviewLimit: 0)

        XCTAssertEqual(session.current?.card.cardType, .new)
        try session.answer(.easy)   // introduction 1 (graduates immediately)
        XCTAssertEqual(session.current?.card.cardType, .new)
        try session.answer(.easy)   // introduction 2
        XCTAssertTrue(session.isFinished,
                      "Third new card must be blocked by newCardLimit = 2")
    }
}
