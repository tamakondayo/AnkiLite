import Foundation
import GRDB

/// Defines the app's own SQLite schema and migrations (separate from the
/// Anki collection format we import from).
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // While iterating it can be convenient to wipe & rebuild on schema change.
        // migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: NoteType.databaseTableName) { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("fields", .text).notNull().defaults(to: "[]")
                t.column("templates", .text).notNull().defaults(to: "[]")
                t.column("css", .text).notNull().defaults(to: "")
                t.column("type", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: Deck.databaseTableName) { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull().indexed()
                t.column("mod", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: Note.databaseTableName) { t in
                t.column("id", .integer).primaryKey()
                t.column("guid", .text).notNull().defaults(to: "")
                t.column("mid", .integer).notNull().indexed()
                t.column("mod", .integer).notNull().defaults(to: 0)
                t.column("tags", .text).notNull().defaults(to: "")
                t.column("flds", .text).notNull().defaults(to: "")
                t.column("sfld", .text).notNull().defaults(to: "")
            }

            try db.create(table: Card.databaseTableName) { t in
                t.column("id", .integer).primaryKey()
                t.column("nid", .integer).notNull().indexed()
                t.column("did", .integer).notNull().indexed()
                t.column("ord", .integer).notNull().defaults(to: 0)
                t.column("mod", .integer).notNull().defaults(to: 0)
                t.column("type", .integer).notNull().defaults(to: 0)
                t.column("queue", .integer).notNull().defaults(to: 0)
                t.column("due", .integer).notNull().defaults(to: 0)
                t.column("ivl", .integer).notNull().defaults(to: 0)
                t.column("factor", .integer).notNull().defaults(to: 2500)
                t.column("reps", .integer).notNull().defaults(to: 0)
                t.column("lapses", .integer).notNull().defaults(to: 0)
                t.column("left", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: ReviewLog.databaseTableName) { t in
                t.column("id", .integer).primaryKey()
                t.column("cid", .integer).notNull().indexed()
                t.column("ease", .integer).notNull().defaults(to: 0)
                t.column("ivl", .integer).notNull().defaults(to: 0)
                t.column("lastIvl", .integer).notNull().defaults(to: 0)
                t.column("factor", .integer).notNull().defaults(to: 0)
                t.column("time", .integer).notNull().defaults(to: 0)
                t.column("type", .integer).notNull().defaults(to: 0)
            }

            // Stores collection creation time (crt) so we can convert
            // review-card `due` (days since crt) into absolute dates.
            try db.create(table: "collectionMeta") { t in
                t.column("id", .integer).primaryKey()
                t.column("crt", .integer).notNull().defaults(to: 0)
            }
        }

        // v2: Anki-style flags column on card (low 3 bits = colour).
        migrator.registerMigration("v2_card_flags") { db in
            try db.alter(table: Card.databaseTableName) { t in
                t.add(column: "flags", .integer).notNull().defaults(to: 0)
            }
        }

        // v3: FSRS memory state on card.
        migrator.registerMigration("v3_fsrs") { db in
            try db.alter(table: Card.databaseTableName) { t in
                t.add(column: "stability", .double).notNull().defaults(to: 0)
                t.add(column: "difficulty", .double).notNull().defaults(to: 0)
                t.add(column: "lastReview", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
