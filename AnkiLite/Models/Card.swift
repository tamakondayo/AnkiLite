import Foundation
import GRDB

/// Card scheduling state.
enum CardType: Int, Codable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

/// Anki queue values (subset used by this app).
enum CardQueue: Int, Codable {
    case suspended = -1
    case new = 0
    case learning = 1
    case review = 2
    case dayLearning = 3
}

/// A single card: an instance of a template applied to a note, with its
/// own scheduling state.
struct Card: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "card"

    var id: Int64
    /// Note id → Note.id.
    var nid: Int64
    /// Deck id → Deck.id.
    var did: Int64
    /// Template index within the note type.
    var ord: Int
    var mod: Int64
    var type: Int
    var queue: Int
    /// For new cards: ordering position. For review cards: days since collection creation.
    /// For (re)learning cards: a Unix timestamp (seconds) of the next due time.
    var due: Int64
    /// Interval in days (negative values are seconds).
    var ivl: Int
    /// Ease factor × 1000 (e.g. 2500 = 2.5).
    var factor: Int
    var reps: Int
    var lapses: Int
    /// Remaining learning steps (encoded; we store the simple remaining count).
    var left: Int

    enum Columns {
        static let id = Column("id")
        static let nid = Column("nid")
        static let did = Column("did")
        static let ord = Column("ord")
        static let mod = Column("mod")
        static let type = Column("type")
        static let queue = Column("queue")
        static let due = Column("due")
        static let ivl = Column("ivl")
        static let factor = Column("factor")
        static let reps = Column("reps")
        static let lapses = Column("lapses")
        static let left = Column("left")
    }

    var cardType: CardType {
        get { CardType(rawValue: type) ?? .new }
        set { type = newValue.rawValue }
    }

    var cardQueue: CardQueue {
        get { CardQueue(rawValue: queue) ?? .new }
        set { queue = newValue.rawValue }
    }

    /// Ease factor as a Double (e.g. 2.5).
    var easeFactor: Double {
        get { Double(factor) / 1000.0 }
        set { factor = Int((newValue * 1000).rounded()) }
    }

    init(id: Int64,
         nid: Int64,
         did: Int64,
         ord: Int,
         mod: Int64 = Int64(Date().timeIntervalSince1970),
         type: Int = 0,
         queue: Int = 0,
         due: Int64 = 0,
         ivl: Int = 0,
         factor: Int = 2500,
         reps: Int = 0,
         lapses: Int = 0,
         left: Int = 0) {
        self.id = id
        self.nid = nid
        self.did = did
        self.ord = ord
        self.mod = mod
        self.type = type
        self.queue = queue
        self.due = due
        self.ivl = ivl
        self.factor = factor
        self.reps = reps
        self.lapses = lapses
        self.left = left
    }
}
