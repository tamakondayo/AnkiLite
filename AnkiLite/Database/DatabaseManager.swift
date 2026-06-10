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

    /// Deletes a deck AND all of its sub-decks (Anki behaviour) — leaving
    /// the children behind would orphan "親::子" rows with no parent.
    /// Cards, their review logs, and notes left without cards go too.
    func deleteDeck(_ deck: Deck) throws {
        try dbQueue.write { db in
            let prefixPattern = Self.escapeLike(deck.name + "::") + "%"
            let deckIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM \(Deck.databaseTableName)
                WHERE id = ? OR name LIKE ? ESCAPE '\\'
                """, arguments: [deck.id, prefixPattern])

            let deckPlaceholders = databaseQuestionMarks(count: deckIds.count)
            let deckArgs = StatementArguments(deckIds)

            let cardIds = try Int64.fetchAll(db,
                sql: "SELECT id FROM \(Card.databaseTableName) WHERE did IN (\(deckPlaceholders))",
                arguments: deckArgs)
            if !cardIds.isEmpty {
                let placeholders = databaseQuestionMarks(count: cardIds.count)
                try db.execute(sql: "DELETE FROM \(ReviewLog.databaseTableName) WHERE cid IN (\(placeholders))",
                               arguments: StatementArguments(cardIds))
            }
            try db.execute(sql: "DELETE FROM \(Card.databaseTableName) WHERE did IN (\(deckPlaceholders))",
                           arguments: deckArgs)
            // Remove notes that no longer have any cards.
            try db.execute(sql: """
                DELETE FROM \(Note.databaseTableName)
                WHERE id NOT IN (SELECT DISTINCT nid FROM \(Card.databaseTableName))
                """)
            try db.execute(sql: "DELETE FROM \(Deck.databaseTableName) WHERE id IN (\(deckPlaceholders))",
                           arguments: deckArgs)
        }
    }

    /// Escapes LIKE metacharacters so deck names containing % or _ match literally.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Renames a deck (and updates all descendant deck names so they remain
    /// nested under the new fully-qualified name).
    ///
    /// - Throws: if `newName` collides with an existing deck.
    func renameDeck(_ deck: Deck, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "DatabaseManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "デッキ名を入力してください。"
            ])
        }
        if trimmed == deck.name { return }

        try dbQueue.write { db in
            // Collision check (case-sensitive, same rule as Anki).
            let conflict = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM \(Deck.databaseTableName) WHERE name = ? AND id != ?",
                arguments: [trimmed, deck.id]) ?? 0
            if conflict > 0 {
                throw NSError(domain: "DatabaseManager", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "同じ名前のデッキが既にあります。"
                ])
            }

            let oldPrefix = deck.name + "::"
            let newPrefix = trimmed + "::"
            let now = Int64(Date().timeIntervalSince1970)

            // Rename the deck itself.
            try db.execute(sql: """
                UPDATE \(Deck.databaseTableName) SET name = ?, mod = ? WHERE id = ?
                """, arguments: [trimmed, now, deck.id])

            // Rename descendants by string-prefix substitution.
            try db.execute(sql: """
                UPDATE \(Deck.databaseTableName)
                SET name = ? || SUBSTR(name, ?),
                    mod = ?
                WHERE name LIKE ?
                """, arguments: [newPrefix, oldPrefix.count + 1, now, oldPrefix + "%"])
        }
    }

    /// Updates the per-deck daily limits (nil clears an override).
    func setDeckLimits(deckId: Int64, newPerDay: Int?, reviewsPerDay: Int?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE \(Deck.databaseTableName)
                SET newPerDay = ?, reviewsPerDay = ?, mod = ?
                WHERE id = ?
                """, arguments: [newPerDay, reviewsPerDay,
                                 Int64(Date().timeIntervalSince1970), deckId])
        }
    }

    // MARK: - Lookups

    func deck(id: Int64) throws -> Deck? {
        try dbQueue.read { db in try Deck.fetchOne(db, key: id) }
    }

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
