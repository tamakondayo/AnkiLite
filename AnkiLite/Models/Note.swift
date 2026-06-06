import Foundation
import GRDB

/// The U+001F separator Anki uses between field values in `notes.flds`.
let ankiFieldSeparator = "\u{1f}"

/// An Anki note: the data (fields) shared by one or more cards.
struct Note: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "note"

    var id: Int64
    var guid: String
    /// Note type id → NoteType.id.
    var mid: Int64
    var mod: Int64
    /// Space-separated tags.
    var tags: String
    /// Field values joined by `ankiFieldSeparator`.
    var flds: String
    /// Sort field (plain text).
    var sfld: String

    enum Columns {
        static let id = Column("id")
        static let guid = Column("guid")
        static let mid = Column("mid")
        static let mod = Column("mod")
        static let tags = Column("tags")
        static let flds = Column("flds")
        static let sfld = Column("sfld")
    }

    init(id: Int64, guid: String, mid: Int64, mod: Int64, tags: String, flds: String, sfld: String) {
        self.id = id
        self.guid = guid
        self.mid = mid
        self.mod = mod
        self.tags = tags
        self.flds = flds
        self.sfld = sfld
    }

    /// The individual field values, in field order.
    var fieldValues: [String] {
        flds.components(separatedBy: ankiFieldSeparator)
    }

    /// The list of tags (whitespace separated, empty entries removed).
    var tagList: [String] {
        tags.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Maps field names → values for the given note type.
    func fieldMap(for noteType: NoteType) -> [String: String] {
        let names = noteType.orderedFieldNames
        let values = fieldValues
        var map: [String: String] = [:]
        for (index, name) in names.enumerated() {
            map[name] = index < values.count ? values[index] : ""
        }
        return map
    }
}
