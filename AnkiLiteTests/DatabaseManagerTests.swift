import XCTest
import GRDB
@testable import AnkiLite

final class DatabaseManagerTests: XCTestCase {

    /// Deleting a parent deck must take its sub-decks (and their cards,
    /// logs and orphaned notes) with it — not leave "親::子" rows behind
    /// with no parent.
    func testDeleteDeckRemovesSubdecksAndTheirData() throws {
        let db = try DatabaseManager.inMemory()
        try db.dbQueue.write { w in
            try Deck(id: 1, name: "親").insert(w)
            try Deck(id: 2, name: "親::子").insert(w)
            try Deck(id: 3, name: "親::子::孫").insert(w)
            try Deck(id: 4, name: "親二号").insert(w)   // similar prefix, NOT a child

            for (cardId, deckId) in [(10, Int64(1)), (20, Int64(2)), (30, Int64(3)), (40, Int64(4))] {
                let id = Int64(cardId)
                try Note(id: id, guid: "g\(id)", mid: 1, mod: 0, tags: "",
                         flds: "f", sfld: "f").insert(w)
                try Card(id: id, nid: id, did: deckId, ord: 0).insert(w)
                try ReviewLog(id: id, cid: id, ease: 3, ivl: 1, lastIvl: 0,
                              factor: 2500, time: 100, type: 0).insert(w)
            }
        }

        let parent = try XCTUnwrap(db.deck(id: 1))
        try db.deleteDeck(parent)

        let remainingDecks = try db.allDecks().map(\.name)
        XCTAssertEqual(remainingDecks, ["親二号"],
                       "Only the unrelated deck should survive")

        try db.dbQueue.read { r in
            let cards = try Int64.fetchAll(r, sql: "SELECT id FROM card ORDER BY id")
            XCTAssertEqual(cards, [40], "Sub-deck cards must be deleted")
            let notes = try Int64.fetchAll(r, sql: "SELECT id FROM note ORDER BY id")
            XCTAssertEqual(notes, [40], "Orphaned notes must be pruned")
            let logs = try Int64.fetchAll(r, sql: "SELECT id FROM reviewLog ORDER BY id")
            XCTAssertEqual(logs, [40], "Sub-deck review logs must be deleted")
        }
    }

    func testEscapeLike() {
        XCTAssertEqual(DatabaseManager.escapeLike("a%b_c\\d"), "a\\%b\\_c\\\\d")
    }
}
