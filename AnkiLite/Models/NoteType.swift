import Foundation
import GRDB

/// A field definition within a note type.
struct NoteField: Codable, Hashable {
    var name: String
    var ord: Int

    enum CodingKeys: String, CodingKey {
        case name
        case ord
    }

    init(name: String, ord: Int) {
        self.name = name
        self.ord = ord
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // `ord` can occasionally be missing or null in older collections.
        ord = (try? container.decode(Int.self, forKey: .ord)) ?? 0
    }
}

/// A card template (question/answer format) within a note type.
struct CardTemplate: Codable, Hashable {
    var name: String
    var ord: Int
    /// Question format (front).
    var qfmt: String
    /// Answer format (back).
    var afmt: String

    enum CodingKeys: String, CodingKey {
        case name
        case ord
        case qfmt
        case afmt
    }

    init(name: String, ord: Int, qfmt: String, afmt: String) {
        self.name = name
        self.ord = ord
        self.qfmt = qfmt
        self.afmt = afmt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        ord = (try? container.decode(Int.self, forKey: .ord)) ?? 0
        qfmt = (try? container.decode(String.self, forKey: .qfmt)) ?? ""
        afmt = (try? container.decode(String.self, forKey: .afmt)) ?? ""
    }
}

/// Anki note type ("model"). Defines fields, templates and styling.
struct NoteType: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "noteType"

    /// Model id (matches `notes.mid`). Stored as the JSON key in `col.models`.
    var id: Int64
    var name: String
    var fields: [NoteField]
    var templates: [CardTemplate]
    var css: String
    /// Anki model type: 0 = standard, 1 = cloze.
    var type: Int

    var isCloze: Bool { type == 1 }

    /// Field names ordered by `ord`.
    var orderedFieldNames: [String] {
        fields.sorted { $0.ord < $1.ord }.map(\.name)
    }

    // GRDB persistence uses JSON-encoded columns for the array fields.
    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let fields = Column("fields")
        static let templates = Column("templates")
        static let css = Column("css")
        static let type = Column("type")
    }

    init(id: Int64, name: String, fields: [NoteField], templates: [CardTemplate], css: String, type: Int) {
        self.id = id
        self.name = name
        self.fields = fields
        self.templates = templates
        self.css = css
        self.type = type
    }

    // MARK: - GRDB row mapping

    init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        css = row["css"]
        type = row["type"]
        let decoder = JSONDecoder()
        let fieldsData: Data = (row["fields"] as String?)?.data(using: .utf8) ?? Data("[]".utf8)
        let templatesData: Data = (row["templates"] as String?)?.data(using: .utf8) ?? Data("[]".utf8)
        fields = (try? decoder.decode([NoteField].self, from: fieldsData)) ?? []
        templates = (try? decoder.decode([CardTemplate].self, from: templatesData)) ?? []
    }

    func encode(to container: inout PersistenceContainer) throws {
        let encoder = JSONEncoder()
        container["id"] = id
        container["name"] = name
        container["css"] = css
        container["type"] = type
        container["fields"] = String(data: try encoder.encode(fields), encoding: .utf8)
        container["templates"] = String(data: try encoder.encode(templates), encoding: .utf8)
    }
}
