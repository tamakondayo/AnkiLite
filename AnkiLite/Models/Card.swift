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
    case buried = -2
    case new = 0
    case learning = 1
    case review = 2
    case dayLearning = 3
}

/// Anki-style colored flag. Stored in the low 3 bits of `card.flags`.
enum CardFlag: Int, Codable, CaseIterable {
    case none = 0
    case red = 1
    case orange = 2
    case green = 3
    case blue = 4
    case pink = 5
    case turquoise = 6
    case purple = 7

    var label: String {
        switch self {
        case .none: return "なし"
        case .red: return "赤"
        case .orange: return "橙"
        case .green: return "緑"
        case .blue: return "青"
        case .pink: return "桃"
        case .turquoise: return "水"
        case .purple: return "紫"
        }
    }

    /// Hex colour for UI.
    var hex: String {
        switch self {
        case .none: return "#888888"
        case .red: return "#e05a4a"
        case .orange: return "#e08a3a"
        case .green: return "#5ba864"
        case .blue: return "#4f8bcf"
        case .pink: return "#d57aa7"
        case .turquoise: return "#4eb6b6"
        case .purple: return "#9b6dc8"
        }
    }
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
    /// Flags bitfield (low 3 bits = colour flag; high bits reserved).
    var flags: Int
    /// FSRS memory state — stability (days). 0 = uninitialised.
    var stability: Double
    /// FSRS memory state — difficulty (1.0…10.0). 0 = uninitialised.
    var difficulty: Double
    /// Unix seconds of the last review (for FSRS elapsed-time calculations).
    var lastReview: Int64

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
        static let flags = Column("flags")
        static let stability = Column("stability")
        static let difficulty = Column("difficulty")
        static let lastReview = Column("lastReview")
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

    /// The colour flag (low 3 bits of `flags`).
    var colorFlag: CardFlag {
        get { CardFlag(rawValue: flags & 0b111) ?? .none }
        set { flags = (flags & ~0b111) | (newValue.rawValue & 0b111) }
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
         left: Int = 0,
         flags: Int = 0,
         stability: Double = 0,
         difficulty: Double = 0,
         lastReview: Int64 = 0) {
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
        self.flags = flags
        self.stability = stability
        self.difficulty = difficulty
        self.lastReview = lastReview
    }
}
