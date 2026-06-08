import Foundation
import GRDB
import Combine

/// Optional filter for a custom-study session.
struct CustomStudyFilter {
    var includeNew: Bool = true
    var includeLearning: Bool = true
    var includeReview: Bool = true
    /// Only include review cards whose due date is in the past.
    var onlyOverdue: Bool = false
    /// Restrict to a specific colour flag (nil = any).
    var flag: CardFlag? = nil
    /// Restrict to notes that have any of these tags (empty = no filter).
    var tags: Set<String> = []
    /// Cap on the total cards served in the session.
    var maxCards: Int = 0
}

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

    /// One step in the undo history.
    /// Captures the card snapshot before the action and the review log id
    /// (if any) that should be deleted on undo.
    struct UndoStep {
        var previousCard: Card
        var previousNote: Note
        var previousNoteType: NoteType
        var insertedReviewLogId: Int64?
        /// What kind of action created this step (used for UI labelling).
        var action: Action
        var elapsedMsAtTime: Int

        enum Action {
            case review(ReviewEase)
            case bury
            case suspend
            case flagChange
        }
    }

    @Published private(set) var current: DueCard?
    @Published private(set) var counts = DeckCounts()
    @Published private(set) var stats = SessionStats()
    @Published private(set) var isFinished = false
    @Published private(set) var canUndo = false

    let deck: Deck
    private let database: DatabaseManager
    private let scheduler: any CardScheduler
    private let crt: Int64
    private var cardStartTime = Date()
    /// Stack of recent reversible actions.
    private var undoStack: [UndoStep] = []
    private let maxUndoDepth = 30
    /// Daily cap on newly introduced cards (0 = unlimited).
    private let newCardLimit: Int
    /// Daily cap on review cards (0 = unlimited).
    private let reviewLimit: Int
    /// Custom-study filter (nil = standard session).
    private let customFilter: CustomStudyFilter?

    /// Sub-decks are studied together with the parent (Anki behaviour).
    private let deckIds: [Int64]

    init(deck: Deck,
         database: DatabaseManager = .shared,
         scheduler: any CardScheduler = SM2Scheduler(),
         newCardLimit: Int = 0,
         reviewLimit: Int = 0,
         customFilter: CustomStudyFilter? = nil) throws {
        self.deck = deck
        self.database = database
        self.scheduler = scheduler
        self.newCardLimit = newCardLimit
        self.reviewLimit = reviewLimit
        self.customFilter = customFilter
        self.crt = (try? database.collectionCreationTime()) ?? 0

        // Include the deck and all of its descendants.
        let allDecks = (try? database.allDecks()) ?? []
        let prefix = deck.name + "::"
        self.deckIds = allDecks
            .filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }
            .map(\.id)

        Self.autoUnbury(database: database)
        try loadNext()
        refreshCounts()
    }

    /// At day rollover, restore buried cards to their natural queue derived
    /// from `type` (new=0 / learning=1 / review=2 / relearning=1).
    private static func autoUnbury(database: DatabaseManager) {
        let lastKey = "lastUnburyDay"
        let now = Int64(Date().timeIntervalSince1970)
        // Calendar day in the device's current locale.
        let today = Int(now / 86_400)
        let lastDay = UserDefaults.standard.integer(forKey: lastKey)
        guard today != lastDay else { return }
        try? database.dbQueue.write { db in
            try db.execute(sql: """
                UPDATE card
                SET queue = CASE
                    WHEN type = 0 THEN 0
                    WHEN type = 1 THEN 1
                    WHEN type = 2 THEN 2
                    WHEN type = 3 THEN 1
                    ELSE 0
                END
                WHERE queue = \(CardQueue.buried.rawValue)
                """)
        }
        UserDefaults.standard.set(today, forKey: lastKey)
    }

    var todayDays: Int { scheduler.today(now: Date(), crt: crt) }
    private var nowCutoff: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Milliseconds-since-epoch for the start of "today" (per the rollover hour),
    /// used to count reviews that fall within the current study day.
    private var todayStartMs: Int64 {
        let dayStart = crt + Int64(todayDays) * 86_400
        return dayStart * 1000
    }

    /// Number of brand-new cards already introduced today.
    /// Counts DISTINCT cards (not log entries) — a single new card is one
    /// "introduction" even if the user pressed Good twice in learning steps.
    private func newCardsIntroducedToday() -> Int {
        guard !deckIds.isEmpty else { return 0 }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)
        return (try? database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT cid) FROM reviewLog
                WHERE id >= \(self.todayStartMs)
                  AND type = 0
                  AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                """, arguments: args) ?? 0
        }) ?? 0
    }

    /// Number of review-card reviews logged today.
    private func reviewsCompletedToday() -> Int {
        guard !deckIds.isEmpty else { return 0 }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)
        return (try? database.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reviewLog
                WHERE id >= \(self.todayStartMs)
                  AND type = 1
                  AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                """, arguments: args) ?? 0
        }) ?? 0
    }

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

    /// Re-fetches and exposes a specific card as current (used by undo).
    private func setCurrent(card: Card) throws {
        guard let note = try database.note(id: card.nid),
              let noteType = try database.noteType(id: note.mid) else {
            try loadNext()
            return
        }
        current = DueCard(card: card, note: note, noteType: noteType)
        cardStartTime = Date()
        isFinished = false
    }

    private func fetchNextDueCard() throws -> Card? {
        guard !deckIds.isEmpty else { return nil }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)
        // Exclude the card currently displayed so Hard/Again don't immediately
        // re-show the same card mid-session.
        let exclude = current?.card.id

        // Custom-study sessions cap by total served cards in this session.
        if let filter = customFilter, filter.maxCards > 0, stats.reviewed >= filter.maxCards {
            return nil
        }

        let newQuota = newCardLimit > 0 && customFilter == nil
            ? max(0, newCardLimit - newCardsIntroducedToday()) : Int.max
        let reviewQuota = reviewLimit > 0 && customFilter == nil
            ? max(0, reviewLimit - reviewsCompletedToday()) : Int.max

        // Optional ID set when a custom filter restricts cards (tag/flag).
        let allowedIds = try customFilterAllowedIds()
        if let allowedIds, allowedIds.isEmpty { return nil }
        let allowedClause = allowedIds.map { ids -> String in
            let list = ids.map { String($0) }.joined(separator: ",")
            return " AND id IN (\(list))"
        } ?? ""

        return try database.dbQueue.read { db -> Card? in
            let excludeClause = exclude.map { " AND id != \($0)" } ?? ""
            let allowNew = customFilter?.includeNew ?? true
            let allowLearning = customFilter?.includeLearning ?? true
            let allowReview = customFilter?.includeReview ?? true
            let overdueOnly = customFilter?.onlyOverdue ?? false

            // 1. Learning/relearning cards due now. (Always served — no daily cap.)
            if allowLearning, let learning = try Card.fetchOne(db, sql: """
                SELECT * FROM card
                WHERE did IN (\(placeholders))
                  AND queue IN (\(CardQueue.learning.rawValue), \(CardQueue.dayLearning.rawValue))
                  AND due <= \(self.nowCutoff)
                  \(excludeClause)
                  \(allowedClause)
                ORDER BY due ASC LIMIT 1
                """, arguments: args) {
                return learning
            }
            // 2. Review cards due today, subject to the daily review cap.
            if allowReview, reviewQuota > 0 {
                let dueClause = overdueOnly ? "due < \(self.todayDays)" : "due <= \(self.todayDays)"
                if let review = try Card.fetchOne(db, sql: """
                    SELECT * FROM card
                    WHERE did IN (\(placeholders))
                      AND queue = \(CardQueue.review.rawValue)
                      AND \(dueClause)
                      \(excludeClause)
                      \(allowedClause)
                    ORDER BY due ASC LIMIT 1
                    """, arguments: args) {
                    return review
                }
            }
            // 3. New cards, subject to the daily new-card cap.
            if allowNew, newQuota > 0,
               let newCard = try Card.fetchOne(db, sql: """
                SELECT * FROM card
                WHERE did IN (\(placeholders))
                  AND queue = \(CardQueue.new.rawValue)
                  \(excludeClause)
                  \(allowedClause)
                ORDER BY due ASC LIMIT 1
                """, arguments: args) {
                return newCard
            }
            return nil
        }
    }

    /// Resolve the set of card ids that satisfy the custom filter (flag + tags).
    /// Returns nil if there is no custom restriction.
    private func customFilterAllowedIds() throws -> Set<Int64>? {
        guard let filter = customFilter else { return nil }
        let needsRestrict = (filter.flag != nil) || !filter.tags.isEmpty
        guard needsRestrict else { return nil }

        let placeholders = databaseQuestionMarks(count: deckIds.count)
        return try database.dbQueue.read { db -> Set<Int64> in
            var sql = """
                SELECT card.id FROM card
                JOIN note ON note.id = card.nid
                WHERE card.did IN (\(placeholders))
                """
            if let flag = filter.flag {
                sql += " AND (card.flags & 7) = \(flag.rawValue)"
            }
            if !filter.tags.isEmpty {
                let tagClauses = filter.tags.map { _ in
                    "(' ' || note.tags || ' ') LIKE ?"
                }.joined(separator: " OR ")
                sql += " AND (\(tagClauses))"
            }
            var values: [(any DatabaseValueConvertible)?] = deckIds.map { $0 as (any DatabaseValueConvertible)? }
            for tag in filter.tags {
                values.append("% \(tag) %")
            }
            let ids = try Int64.fetchAll(db, sql: sql,
                                         arguments: StatementArguments(values))
            return Set(ids)
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

        pushUndo(UndoStep(previousCard: due.card,
                          previousNote: due.note,
                          previousNoteType: due.noteType,
                          insertedReviewLogId: result.log.id,
                          action: .review(ease),
                          elapsedMsAtTime: elapsedMs))

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

    // MARK: - Undo

    private func pushUndo(_ step: UndoStep) {
        undoStack.append(step)
        if undoStack.count > maxUndoDepth { undoStack.removeFirst(undoStack.count - maxUndoDepth) }
        canUndo = true
    }

    /// Undoes the most recent action (review/bury/suspend/flag).
    func undo() throws {
        guard let step = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty

        // Restore the card.
        try database.saveCard(step.previousCard)

        // Remove the inserted review log (if any).
        if let logId = step.insertedReviewLogId {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM \(ReviewLog.databaseTableName) WHERE id = ?",
                               arguments: [logId])
            }
        }

        // Roll back session stats for review undos.
        if case .review(let ease) = step.action {
            stats.reviewed = max(0, stats.reviewed - 1)
            stats.totalTimeMs = max(0, stats.totalTimeMs - step.elapsedMsAtTime)
            if ease == .again { stats.again = max(0, stats.again - 1) }
        }

        try setCurrent(card: step.previousCard)
        refreshCounts()
    }

    // MARK: - Bury / Suspend

    /// Buries the current card (hidden today; auto-unburies at day rollover).
    func buryCurrent() throws {
        guard let due = current else { return }
        var updated = due.card
        updated.cardQueue = .buried
        updated.mod = Int64(Date().timeIntervalSince1970)

        pushUndo(UndoStep(previousCard: due.card,
                          previousNote: due.note,
                          previousNoteType: due.noteType,
                          insertedReviewLogId: nil,
                          action: .bury,
                          elapsedMsAtTime: 0))

        try database.saveCard(updated)
        try loadNext()
        refreshCounts()
    }

    /// Suspends the current card (removes from the learning queue indefinitely).
    func suspendCurrent() throws {
        guard let due = current else { return }
        var updated = due.card
        updated.cardQueue = .suspended
        updated.mod = Int64(Date().timeIntervalSince1970)

        pushUndo(UndoStep(previousCard: due.card,
                          previousNote: due.note,
                          previousNoteType: due.noteType,
                          insertedReviewLogId: nil,
                          action: .suspend,
                          elapsedMsAtTime: 0))

        try database.saveCard(updated)
        try loadNext()
        refreshCounts()
    }

    /// Sets a colored flag.
    func setFlag(_ flag: CardFlag) throws {
        guard let due = current else { return }
        var updated = due.card
        updated.colorFlag = flag
        updated.mod = Int64(Date().timeIntervalSince1970)

        pushUndo(UndoStep(previousCard: due.card,
                          previousNote: due.note,
                          previousNoteType: due.noteType,
                          insertedReviewLogId: nil,
                          action: .flagChange,
                          elapsedMsAtTime: 0))

        try database.saveCard(updated)
        // Stay on the same card; just refresh.
        try setCurrent(card: updated)
    }

    var currentFlag: CardFlag {
        current?.card.colorFlag ?? .none
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
