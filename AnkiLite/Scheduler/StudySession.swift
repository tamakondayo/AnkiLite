import Foundation
import GRDB
import Combine

/// Drives a study session for a single deck: fetches the due queue, serves
/// cards one at a time, and applies scheduling answers.
@MainActor
final class StudySession: ObservableObject {

    struct DueCard: Identifiable {
        var card: Card
        var note: Note
        var noteType: NoteType
        var id: Int64 { card.id }
    }

    struct SessionStats {
        var reviewed: Int = 0
        var again: Int = 0
        var totalTimeMs: Int = 0
    }

    @Published private(set) var current: DueCard?
    @Published private(set) var counts = DeckCounts()
    @Published private(set) var stats = SessionStats()
    @Published private(set) var isFinished = false

    let deck: Deck
    private let database: DatabaseManager
    private let scheduler: SM2Scheduler
    private let crt: Int64
    private var cardStartTime = Date()

    /// Sub-decks are studied together with the parent (Anki behaviour).
    private let deckIds: [Int64]

    init(deck: Deck,
         database: DatabaseManager = .shared,
         scheduler: SM2Scheduler = SM2Scheduler()) throws {
        self.deck = deck
        self.database = database
        self.scheduler = scheduler
        self.crt = (try? database.collectionCreationTime()) ?? 0

        // Include the deck and all of its descendants.
        let allDecks = (try? database.allDecks()) ?? []
        let prefix = deck.name + "::"
        self.deckIds = allDecks
            .filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }
            .map(\.id)

        try loadNext()
        refreshCounts()
    }

    var todayDays: Int { scheduler.today(now: Date(), crt: crt) }
    private var nowCutoff: Int64 { Int64(Date().timeIntervalSince1970) }

    // MARK: - Queue

    /// Loads the next due card into `current`, or finishes the session.
    func loadNext() throws {
        let card = try fetchNextDueCard()
        guard let card else {
            current = nil
            isFinished = true
            return
        }
        guard let note = try database.note(id: card.nid),
              let noteType = try database.noteType(id: note.mid) else {
            // Skip cards whose note/model is missing.
            try markBrokenAndAdvance(card)
            return
        }
        current = DueCard(card: card, note: note, noteType: noteType)
        cardStartTime = Date()
    }

    private func fetchNextDueCard() throws -> Card? {
        guard !deckIds.isEmpty else { return nil }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)

        return try database.dbQueue.read { db -> Card? in
            // 1. Learning/relearning cards due now.
            if let learning = try Card.fetchOne(db, sql: """
                SELECT * FROM card
                WHERE did IN (\(placeholders))
                  AND queue IN (\(CardQueue.learning.rawValue), \(CardQueue.dayLearning.rawValue))
                  AND due <= \(self.nowCutoff)
                ORDER BY due ASC LIMIT 1
                """, arguments: args) {
                return learning
            }
            // 2. Review cards due today.
            if let review = try Card.fetchOne(db, sql: """
                SELECT * FROM card
                WHERE did IN (\(placeholders))
                  AND queue = \(CardQueue.review.rawValue)
                  AND due <= \(self.todayDays)
                ORDER BY due ASC LIMIT 1
                """, arguments: args) {
                return review
            }
            // 3. New cards.
            if let newCard = try Card.fetchOne(db, sql: """
                SELECT * FROM card
                WHERE did IN (\(placeholders))
                  AND queue = \(CardQueue.new.rawValue)
                ORDER BY due ASC LIMIT 1
                """, arguments: args) {
                return newCard
            }
            return nil
        }
    }

    private func markBrokenAndAdvance(_ card: Card) throws {
        var broken = card
        broken.cardQueue = .suspended
        try database.saveCard(broken)
        try loadNext()
    }

    // MARK: - Answering

    /// Applies an answer to the current card and advances the queue.
    func answer(_ ease: ReviewEase) throws {
        guard let due = current else { return }
        let elapsedMs = Int(Date().timeIntervalSince(cardStartTime) * 1000)
        let result = scheduler.answer(card: due.card,
                                      ease: ease,
                                      now: Date(),
                                      crt: crt,
                                      timeTakenMs: elapsedMs)
        try database.saveCard(result.card)
        try database.insertReviewLog(result.log)

        stats.reviewed += 1
        stats.totalTimeMs += elapsedMs
        if ease == .again { stats.again += 1 }

        try loadNext()
        refreshCounts()
    }

    /// Interval preview labels for the answer buttons of the current card.
    func intervalLabels() -> [ReviewEase: String] {
        guard let due = current else { return [:] }
        return scheduler.previewIntervals(for: due.card)
    }

    // MARK: - Counts

    func refreshCounts() {
        var total = DeckCounts()
        for id in deckIds {
            if let c = try? database.counts(forDeckId: id, todayCutoff: nowCutoff, todayDays: todayDays) {
                total = total + c
            }
        }
        counts = total
    }
}
