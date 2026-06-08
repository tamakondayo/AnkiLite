import Foundation
import GRDB
import ZIPFoundation

/// Errors surfaced during apkg import.
enum ImportError: LocalizedError {
    case cannotOpenArchive
    case noCollectionDatabase
    case databaseUnreadable(String)
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive:
            return "apkgファイルを開けませんでした。ファイルが破損しているか、対応していない形式です。"
        case .noCollectionDatabase:
            return "コレクションデータベース (collection.anki21 / collection.anki2) が見つかりませんでした。"
        case .databaseUnreadable(let detail):
            return "データベースの読み込みに失敗しました: \(detail)"
        case .insufficientStorage:
            return "ストレージの空き容量が不足しています。"
        }
    }
}

/// How to handle decks that already exist when re-importing.
enum ImportMode {
    /// Replace existing content for matching decks/notes.
    case overwrite
    /// Keep existing content and add new (skip duplicates by id).
    case merge
}

/// Progress callback payload.
struct ImportProgress {
    var fraction: Double          // 0.0 ... 1.0
    var message: String
}

/// Imports an Anki `.apkg` package into the app's own database.
final class ApkgImporter {

    private let database: DatabaseManager
    private let media: MediaManager

    init(database: DatabaseManager = .shared, media: MediaManager = .shared) {
        self.database = database
        self.media = media
    }

    /// Imports the apkg at `url`.
    /// - Parameters:
    ///   - url: the .apkg file.
    ///   - mode: overwrite vs merge.
    ///   - progress: progress callback (called on an arbitrary queue).
    func importPackage(from url: URL,
                       mode: ImportMode = .overwrite,
                       progress: ((ImportProgress) -> Void)? = nil) throws {
        progress?(ImportProgress(fraction: 0.0, message: "パッケージを展開中…"))

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // 1. Unzip.
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw ImportError.cannotOpenArchive
        }
        try extractArchive(archive, to: workDir)

        // 2. Locate the collection database (prefer the newer anki21 format).
        let anki21 = workDir.appendingPathComponent("collection.anki21")
        let anki2 = workDir.appendingPathComponent("collection.anki2")
        let collectionURL: URL
        if FileManager.default.fileExists(atPath: anki21.path) {
            collectionURL = anki21
        } else if FileManager.default.fileExists(atPath: anki2.path) {
            collectionURL = anki2
        } else {
            throw ImportError.noCollectionDatabase
        }

        progress?(ImportProgress(fraction: 0.2, message: "コレクションを読み込み中…"))

        // 3. Read the Anki collection.
        let parsed = try readCollection(at: collectionURL)

        progress?(ImportProgress(fraction: 0.5, message: "カードを保存中…"))

        // 4. Persist into our database.
        try persist(parsed, mode: mode)

        progress?(ImportProgress(fraction: 0.8, message: "メディアを取り込み中…"))

        // 5. Import media files.
        importMedia(from: workDir)

        progress?(ImportProgress(fraction: 1.0, message: "完了"))
    }

    // MARK: - Unzip

    private func extractArchive(_ archive: Archive, to dir: URL) throws {
        for entry in archive {
            let destination = dir.appendingPathComponent(entry.path)
            // Guard against zip-slip.
            guard destination.path.hasPrefix(dir.path) else { continue }
            if entry.type == .directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: destination)
            }
        }
    }

    // MARK: - Read Anki collection

    private struct ParsedCollection {
        var crt: Int64
        var noteTypes: [NoteType]
        var decks: [Deck]
        var notes: [Note]
        var cards: [Card]
        var reviewLogs: [ReviewLog]
    }

    private func readCollection(at url: URL) throws -> ParsedCollection {
        var config = Configuration()
        config.readonly = true
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw ImportError.databaseUnreadable(error.localizedDescription)
        }

        return try queue.read { db -> ParsedCollection in
            // --- col row ---
            guard let colRow = try Row.fetchOne(db, sql: "SELECT crt, models, decks FROM col LIMIT 1") else {
                throw ImportError.databaseUnreadable("col テーブルが空です。")
            }
            let crt: Int64 = colRow["crt"] ?? 0
            let modelsJSON: String = colRow["models"] ?? "{}"
            let decksJSON: String = colRow["decks"] ?? "{}"

            let noteTypes = Self.parseModels(modelsJSON)
            let decks = Self.parseDecks(decksJSON)

            // --- notes ---
            var notes: [Note] = []
            let noteRows = try Row.fetchCursor(db, sql: "SELECT id, guid, mid, mod, tags, flds, sfld FROM notes")
            while let row = try noteRows.next() {
                notes.append(Note(
                    id: row["id"],
                    guid: row["guid"] ?? "",
                    mid: row["mid"],
                    mod: row["mod"] ?? 0,
                    tags: row["tags"] ?? "",
                    flds: row["flds"] ?? "",
                    sfld: Self.stringValue(row["sfld"])
                ))
            }

            // --- cards ---
            var cards: [Card] = []
            let cardRows = try Row.fetchCursor(db, sql: """
                SELECT id, nid, did, ord, mod, type, queue, due, ivl, factor, reps, lapses, "left", flags FROM cards
                """)
            while let row = try cardRows.next() {
                // Anki encodes `left` as "remaining_steps * 1000 + today_count",
                // while this app uses it as "completed_steps". Renumber on import:
                // - new cards stay at 0
                // - (re)learning cards restart their learning sequence from step 0
                // - review cards keep whatever (they ignore `left`)
                let importedType = row["type"] as Int? ?? 0
                let importedLeft: Int
                switch importedType {
                case 0, 1, 3: importedLeft = 0   // new / learning / relearning → fresh
                default:      importedLeft = 0   // review and others — `left` is unused
                }
                cards.append(Card(
                    id: row["id"],
                    nid: row["nid"],
                    did: row["did"],
                    ord: row["ord"] ?? 0,
                    mod: row["mod"] ?? 0,
                    type: importedType,
                    queue: row["queue"] ?? 0,
                    due: row["due"] ?? 0,
                    ivl: row["ivl"] ?? 0,
                    factor: (row["factor"] as Int?).map { $0 == 0 ? 2500 : $0 } ?? 2500,
                    reps: row["reps"] ?? 0,
                    lapses: row["lapses"] ?? 0,
                    left: importedLeft,
                    flags: row["flags"] ?? 0
                ))
            }

            // --- revlog (optional) ---
            var reviewLogs: [ReviewLog] = []
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='revlog'") ?? false {
                let revRows = try Row.fetchCursor(db, sql: """
                    SELECT id, cid, ease, ivl, lastIvl, factor, time, type FROM revlog
                    """)
                while let row = try revRows.next() {
                    reviewLogs.append(ReviewLog(
                        id: row["id"],
                        cid: row["cid"],
                        ease: row["ease"] ?? 0,
                        ivl: row["ivl"] ?? 0,
                        lastIvl: row["lastIvl"] ?? 0,
                        factor: row["factor"] ?? 0,
                        time: row["time"] ?? 0,
                        type: row["type"] ?? 0
                    ))
                }
            }

            return ParsedCollection(crt: crt,
                                    noteTypes: noteTypes,
                                    decks: decks,
                                    notes: notes,
                                    cards: cards,
                                    reviewLogs: reviewLogs)
        }
    }

    /// `sfld` can be stored as text or numeric; normalize to a string.
    private static func stringValue(_ value: DatabaseValue?) -> String {
        guard let value else { return "" }
        switch value.storage {
        case .string(let s): return s
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        default: return ""
        }
    }

    // MARK: - JSON parsing

    static func parseModels(_ json: String) -> [NoteType] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var result: [NoteType] = []
        for (key, value) in object {
            guard let dict = value as? [String: Any] else { continue }
            let id = (dict["id"] as? Int64) ?? (dict["id"] as? Int).map(Int64.init) ?? Int64(key) ?? 0
            let name = dict["name"] as? String ?? "Unknown"
            let css = dict["css"] as? String ?? ""
            let type = dict["type"] as? Int ?? 0

            var fields: [NoteField] = []
            if let flds = dict["flds"] as? [[String: Any]] {
                for f in flds {
                    let fname = f["name"] as? String ?? ""
                    let ord = f["ord"] as? Int ?? fields.count
                    fields.append(NoteField(name: fname, ord: ord))
                }
            }

            var templates: [CardTemplate] = []
            if let tmpls = dict["tmpls"] as? [[String: Any]] {
                for t in tmpls {
                    templates.append(CardTemplate(
                        name: t["name"] as? String ?? "",
                        ord: t["ord"] as? Int ?? templates.count,
                        qfmt: t["qfmt"] as? String ?? "",
                        afmt: t["afmt"] as? String ?? ""
                    ))
                }
            }

            result.append(NoteType(id: id, name: name, fields: fields, templates: templates, css: css, type: type))
        }
        return result
    }

    static func parseDecks(_ json: String) -> [Deck] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var result: [Deck] = []
        for (key, value) in object {
            guard let dict = value as? [String: Any] else { continue }
            let id = (dict["id"] as? Int64) ?? (dict["id"] as? Int).map(Int64.init) ?? Int64(key) ?? 0
            let name = dict["name"] as? String ?? "Default"
            let mod = (dict["mod"] as? Int64) ?? (dict["mod"] as? Int).map(Int64.init) ?? 0
            result.append(Deck(id: id, name: name, mod: mod))
        }
        return result
    }

    // MARK: - Persist

    private func persist(_ parsed: ParsedCollection, mode: ImportMode) throws {
        try database.setCollectionCreationTime(parsed.crt)
        try database.dbQueue.write { db in
            for noteType in parsed.noteTypes {
                try noteType.save(db)
            }
            for deck in parsed.decks {
                if mode == .overwrite {
                    try deck.save(db)
                } else if try Deck.fetchOne(db, key: deck.id) == nil {
                    try deck.insert(db)
                }
            }
            for note in parsed.notes {
                if mode == .overwrite {
                    try note.save(db)
                } else if try Note.fetchOne(db, key: note.id) == nil {
                    try note.insert(db)
                }
            }
            for card in parsed.cards {
                if mode == .overwrite {
                    try card.save(db)
                } else if try Card.fetchOne(db, key: card.id) == nil {
                    try card.insert(db)
                }
            }
            for log in parsed.reviewLogs {
                // Review logs are keyed by timestamp; ignore conflicts.
                try? log.insert(db)
            }
        }
    }

    // MARK: - Media

    private func importMedia(from workDir: URL) {
        let manifestURL = workDir.appendingPathComponent("media")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { return }
        let manifest = media.parseManifest(manifestData)
        media.importMedia(manifest: manifest) { number in
            let fileURL = workDir.appendingPathComponent(number)
            return try? Data(contentsOf: fileURL)
        }
    }
}
