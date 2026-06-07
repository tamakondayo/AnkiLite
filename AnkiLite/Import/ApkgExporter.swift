import Foundation
import GRDB
import ZIPFoundation

/// Errors surfaced during apkg export.
enum ExportError: LocalizedError {
    case workspaceFailure
    case zipFailure

    var errorDescription: String? {
        switch self {
        case .workspaceFailure: return "一時ファイルの作成に失敗しました。"
        case .zipFailure: return "ZIP の書き出しに失敗しました。"
        }
    }
}

/// Writes a single-deck (with descendants) apkg package suitable for Anki
/// desktop / AnkiMobile import.
///
/// Produces an Anki 2.1-style archive: `collection.anki21` + media manifest +
/// numbered media files, all zipped.
final class ApkgExporter {

    private let database: DatabaseManager
    private let media: MediaManager

    init(database: DatabaseManager = .shared, media: MediaManager = .shared) {
        self.database = database
        self.media = media
    }

    /// Exports the deck (and descendants) to a new `.apkg` URL.
    /// - Parameter destination: directory in which to write the package.
    /// - Returns: the URL of the created apkg.
    func export(deck: Deck, to destination: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Resolve deck + descendant ids up front (used in both phases).
        let allDecks = try database.allDecks()
        let prefix = deck.name + "::"
        let descendants = allDecks.filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }
        let deckIds = Array(Set(descendants.map(\.id)))
        guard !deckIds.isEmpty else { throw ExportError.workspaceFailure }

        // 1. Pull everything we need from the app database (read-only).
        let payload = try readPayload(deckIds: deckIds, descendants: descendants)

        // 2. Build collection.anki21 inside the work directory.
        let collectionURL = work.appendingPathComponent("collection.anki21")
        try writeCollection(at: collectionURL, payload: payload)

        // 3. Copy media files referenced by the exported notes; build manifest.
        let manifest = try copyMedia(into: work, notes: payload.notes)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [])
        try manifestData.write(to: work.appendingPathComponent("media"))

        // 4. Zip everything into <deckName>.apkg.
        let safeName = deck.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let outURL = destination.appendingPathComponent("\(safeName).apkg")
        try? fm.removeItem(at: outURL)

        guard let archive = Archive(url: outURL, accessMode: .create) else {
            throw ExportError.zipFailure
        }
        for entry in try fm.contentsOfDirectory(atPath: work.path) {
            try archive.addEntry(with: entry,
                                 relativeTo: work,
                                 compressionMethod: .deflate)
        }
        return outURL
    }

    // MARK: - Payload

    private struct Payload {
        var crt: Int64
        var descendants: [Deck]
        var notes: [Note]
        var cards: [Card]
        var models: [NoteType]
        var reviewLogs: [ReviewLog]
    }

    private func readPayload(deckIds: [Int64], descendants: [Deck]) throws -> Payload {
        try database.dbQueue.read { db in
            let placeholders = databaseQuestionMarks(count: deckIds.count)
            let args = StatementArguments(deckIds)
            let cards = try Card.fetchAll(db,
                sql: "SELECT * FROM card WHERE did IN (\(placeholders))",
                arguments: args)

            let noteIds = Array(Set(cards.map(\.nid)))
            let notes: [Note]
            if noteIds.isEmpty {
                notes = []
            } else {
                let nplaceholders = databaseQuestionMarks(count: noteIds.count)
                notes = try Note.fetchAll(db,
                    sql: "SELECT * FROM note WHERE id IN (\(nplaceholders))",
                    arguments: StatementArguments(noteIds))
            }

            let modelIds = Array(Set(notes.map(\.mid)))
            let models: [NoteType]
            if modelIds.isEmpty {
                models = []
            } else {
                let mplaceholders = databaseQuestionMarks(count: modelIds.count)
                models = try NoteType.fetchAll(db,
                    sql: "SELECT * FROM noteType WHERE id IN (\(mplaceholders))",
                    arguments: StatementArguments(modelIds))
            }

            let cardIds = cards.map(\.id)
            let reviewLogs: [ReviewLog]
            if cardIds.isEmpty {
                reviewLogs = []
            } else {
                let cplaceholders = databaseQuestionMarks(count: cardIds.count)
                reviewLogs = try ReviewLog.fetchAll(db,
                    sql: "SELECT * FROM reviewLog WHERE cid IN (\(cplaceholders))",
                    arguments: StatementArguments(cardIds))
            }

            let crt = try Int64.fetchOne(db,
                sql: "SELECT crt FROM collectionMeta WHERE id = 1") ?? Int64(Date().timeIntervalSince1970)

            return Payload(crt: crt,
                           descendants: descendants,
                           notes: notes,
                           cards: cards,
                           models: models,
                           reviewLogs: reviewLogs)
        }
    }

    // MARK: - Anki database construction

    private func writeCollection(at url: URL, payload: Payload) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try Self.createAnkiSchema(db)

            // Build the `col.models` JSON object.
            var modelsObj: [String: Any] = [:]
            for m in payload.models {
                modelsObj["\(m.id)"] = [
                    "id": m.id,
                    "name": m.name,
                    "type": m.type,
                    "css": m.css,
                    "flds": m.fields.map { ["name": $0.name, "ord": $0.ord] },
                    "tmpls": m.templates.map {
                        ["name": $0.name, "ord": $0.ord, "qfmt": $0.qfmt, "afmt": $0.afmt]
                    }
                ]
            }
            var decksObj: [String: Any] = [:]
            for d in payload.descendants {
                decksObj["\(d.id)"] = ["id": d.id, "name": d.name, "mod": d.mod]
            }

            let modelsJSON = String(data: try JSONSerialization.data(withJSONObject: modelsObj),
                                    encoding: .utf8) ?? "{}"
            let decksJSON = String(data: try JSONSerialization.data(withJSONObject: decksObj),
                                   encoding: .utf8) ?? "{}"
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            try db.execute(sql: """
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, '{}', ?, ?, '{}', '{}')
                """, arguments: [payload.crt, nowMs, nowMs, modelsJSON, decksJSON])

            for n in payload.notes {
                try db.execute(sql: """
                    INSERT INTO notes (id, guid, mid, mod, usn, tags, flds, sfld, csum, flags, data)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, 0, 0, '')
                    """, arguments: [n.id, n.guid, n.mid, n.mod, n.tags, n.flds, n.sfld])
            }
            for c in payload.cards {
                try db.execute(sql: """
                    INSERT INTO cards (id, nid, did, ord, mod, usn, type, queue, due, ivl, factor, reps,
                                       lapses, "left", odue, odid, flags, data)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, '')
                    """, arguments: [c.id, c.nid, c.did, c.ord, c.mod, c.type, c.queue, c.due,
                                     c.ivl, c.factor, c.reps, c.lapses, c.left, c.flags])
            }
            for r in payload.reviewLogs {
                try db.execute(sql: """
                    INSERT INTO revlog (id, cid, usn, ease, ivl, lastIvl, factor, time, type)
                    VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id, r.cid, r.ease, r.ivl, r.lastIvl, r.factor, r.time, r.type])
            }
        }
    }

    private static func createAnkiSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE col (id INTEGER PRIMARY KEY, crt INTEGER, mod INTEGER, scm INTEGER, ver INTEGER,
                              dty INTEGER, usn INTEGER, ls INTEGER, conf TEXT, models TEXT,
                              decks TEXT, dconf TEXT, tags TEXT);
            CREATE TABLE notes (id INTEGER PRIMARY KEY, guid TEXT, mid INTEGER, mod INTEGER, usn INTEGER,
                                tags TEXT, flds TEXT, sfld INTEGER, csum INTEGER, flags INTEGER, data TEXT);
            CREATE TABLE cards (id INTEGER PRIMARY KEY, nid INTEGER, did INTEGER, ord INTEGER, mod INTEGER,
                                usn INTEGER, type INTEGER, queue INTEGER, due INTEGER, ivl INTEGER,
                                factor INTEGER, reps INTEGER, lapses INTEGER, "left" INTEGER,
                                odue INTEGER, odid INTEGER, flags INTEGER, data TEXT);
            CREATE TABLE revlog (id INTEGER PRIMARY KEY, cid INTEGER, usn INTEGER, ease INTEGER,
                                 ivl INTEGER, lastIvl INTEGER, factor INTEGER, time INTEGER, type INTEGER);
            CREATE INDEX ix_notes_mid ON notes (mid);
            CREATE INDEX ix_cards_nid ON cards (nid);
            CREATE INDEX ix_cards_did ON cards (did);
            CREATE INDEX ix_revlog_cid ON revlog (cid);
            """)
    }

    // MARK: - Media

    /// Copies media files referenced by the exported notes into the work
    /// directory, numbered 0,1,2…, and returns a [number: filename] manifest.
    private func copyMedia(into work: URL, notes: [Note]) throws -> [String: String] {
        var refs = Set<String>()
        let imgRegex = try? NSRegularExpression(pattern: "<img[^>]*src=\"([^\"]+)\"", options: [.caseInsensitive])
        let sndRegex = try? NSRegularExpression(pattern: "\\[sound:([^\\]]+)\\]")

        for note in notes {
            let text = note.flds
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            if let imgRegex {
                for m in imgRegex.matches(in: text, range: fullRange) {
                    refs.insert(nsText.substring(with: m.range(at: 1)))
                }
            }
            if let sndRegex {
                for m in sndRegex.matches(in: text, range: fullRange) {
                    refs.insert(nsText.substring(with: m.range(at: 1)))
                }
            }
        }

        var manifest: [String: String] = [:]
        let fm = FileManager.default
        var index = 0
        for filename in refs {
            let src = media.url(forMediaNamed: filename)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = work.appendingPathComponent("\(index)")
            try fm.copyItem(at: src, to: dst)
            manifest["\(index)"] = filename
            index += 1
        }
        return manifest
    }
}
