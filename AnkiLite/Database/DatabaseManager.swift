import Foundation
import GRDB

/// Central GRDB database access point for the app's own collection store.
final class DatabaseManager {
    static let shared = try! DatabaseManager()

    let dbQueue: DatabaseQueue

    /// Designated initializer. Pass a custom path for tests (e.g. an
    /// in-memory database via `DatabaseQueue()`), otherwise the on-disk
    /// store in Application Support is used.
    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Schema.migrator().migrate(dbQueue)
    }

    convenience init() throws {
        let url = try Self.defaultDatabaseURL()
        var config = Configuration()
        config.foreignKeysEnabled = false // Anki ids are managed manually.
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try self.init(dbQueue: queue)
    }

    /// An in-memory instance, primarily for unit tests.
    static func inMemory() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue())
    }

    static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
        let dir = support.appendingPathComponent("AnkiLite", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("collection.sqlite")
    }

    // MARK: - Collection meta

    func collectionCreationTime() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT crt FROM collectionMeta WHERE id = 1") ?? 0
        }
    }

    func setCollectionCreationTime(_ crt: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO collectionMeta (id, crt) VALUES (1, ?)",
                           arguments: [crt])
        }
    }

    // MARK: - Decks

    func allDecks() throws -> [Deck] {
        try dbQueue.read { db in
            try Deck.order(Deck.Columns.name).fetchAll(db)
        }
    }

    func deleteDeck(_ deck: Deck) throws {
        try dbQueue.write { db in
            // Delete cards in the deck, then orphaned notes & reviewlogs.
            let cardIds = try Int64.fetchAll(db,
                sql: "SELECT id FROM \(Card.databaseTableName) WHERE did = ?",
                arguments: [deck.id])
            if !cardIds.isEmpty {
                let placeholders = databaseQuestionMarks(count: cardIds.count)
                try db.execute(sql: "DELETE FROM \(ReviewLog.databaseTableName) WHERE cid IN (\(placeholders))",
                               arguments: StatementArguments(cardIds))
            }
            try db.execute(sql: "DELETE FROM \(Card.databaseTableName) WHERE did = ?", arguments: [deck.id])
            // Remove notes that no longer have any cards.
            try db.execute(sql: """
                DELETE FROM \(Note.databaseTableName)
                WHERE id NOT IN (SELECT DISTINCT nid FROM \(Card.databaseTableName))
                """)
            try deck.delete(db)
        }
    }

    // MARK: - Lookups

    func noteType(id: Int64) throws -> NoteType? {
        try dbQueue.read { db in try NoteType.fetchOne(db, key: id) }
    }

    func note(id: Int64) throws -> Note? {
        try dbQueue.read { db in try Note.fetchOne(db, key: id) }
    }

    func card(id: Int64) throws -> Card? {
        try dbQueue.read { db in try Card.fetchOne(db, key: id) }
    }

    // MARK: - Counts

    /// Counts of new/learning/review cards that are currently due for a deck.
    func counts(forDeckId deckId: Int64, todayCutoff: Int64, todayDays: Int) throws -> DeckCounts {
        try dbQueue.read { db in
            var counts = DeckCounts()
            counts.new = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did = ? AND queue = ?",
                arguments: [deckId, CardQueue.new.rawValue]) ?? 0
            // Learning cards due now (due stored as timestamp seconds).
            counts.learning = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did = ? AND queue IN (?, ?) AND due <= ?",
                arguments: [deckId, CardQueue.learning.rawValue, CardQueue.dayLearning.rawValue, todayCutoff]) ?? 0
            // Review cards due today or earlier (due stored as day number).
            counts.review = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did = ? AND queue = ? AND due <= ?",
                arguments: [deckId, CardQueue.review.rawValue, todayDays]) ?? 0
            return counts
        }
    }

    // MARK: - Persistence helpers

    func saveCard(_ card: Card) throws {
        try dbQueue.write { db in try card.update(db) }
    }

    func insertReviewLog(_ log: ReviewLog) throws {
        try dbQueue.write { db in try log.insert(db) }
    }
}

/// Builds a "?, ?, ?" placeholder string for IN clauses.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
