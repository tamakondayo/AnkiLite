import Foundation
import GRDB

/// A deck of cards. Anki deck names use `::` to denote hierarchy,
/// e.g. "日本史::古代".
struct Deck: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deck"

    var id: Int64
    /// Full deck name including `::` separators.
    var name: String
    /// Last modification time (Unix seconds).
    var mod: Int64

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let mod = Column("mod")
    }

    init(id: Int64, name: String, mod: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.id = id
        self.name = name
        self.mod = mod
    }

    /// The components of a hierarchical deck name.
    var components: [String] {
        name.components(separatedBy: "::")
    }

    /// The leaf (display) name of the deck.
    var displayName: String {
        components.last ?? name
    }

    /// Nesting depth (0 for top-level decks).
    var depth: Int {
        components.count - 1
    }

    /// The name of the parent deck, or nil for a top-level deck.
    var parentName: String? {
        let parts = components
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "::")
    }
}

/// Aggregated card counts used in the deck list UI.
struct DeckCounts: Equatable {
    var new: Int = 0
    var learning: Int = 0
    var review: Int = 0

    var total: Int { new + learning + review }

    static func + (lhs: DeckCounts, rhs: DeckCounts) -> DeckCounts {
        DeckCounts(new: lhs.new + rhs.new,
                   learning: lhs.learning + rhs.learning,
                   review: lhs.review + rhs.review)
    }
}
