import XCTest
import GRDB
@testable import AnkiLite

final class ApkgImportTests: XCTestCase {

    // MARK: - Model JSON parsing

    func testParseBasicModel() {
        let json = """
        {
          "1234567890": {
            "id": 1234567890,
            "name": "Basic",
            "type": 0,
            "flds": [
              {"name": "Front", "ord": 0},
              {"name": "Back", "ord": 1}
            ],
            "tmpls": [
              {"name": "Card 1", "ord": 0, "qfmt": "{{Front}}", "afmt": "{{FrontSide}}<hr id=answer>{{Back}}"}
            ],
            "css": ".card { color: black; }"
          }
        }
        """
        let models = ApkgImporter.parseModels(json)
        XCTAssertEqual(models.count, 1)
        let model = models[0]
        XCTAssertEqual(model.id, 1234567890)
        XCTAssertEqual(model.name, "Basic")
        XCTAssertEqual(model.orderedFieldNames, ["Front", "Back"])
        XCTAssertEqual(model.templates.count, 1)
        XCTAssertEqual(model.templates[0].qfmt, "{{Front}}")
        XCTAssertFalse(model.isCloze)
    }

    func testParseClozeModel() {
        let json = """
        {
          "999": {
            "id": 999,
            "name": "Cloze",
            "type": 1,
            "flds": [{"name": "Text", "ord": 0}],
            "tmpls": [{"name": "Cloze", "ord": 0, "qfmt": "{{cloze:Text}}", "afmt": "{{cloze:Text}}"}],
            "css": ""
          }
        }
        """
        let models = ApkgImporter.parseModels(json)
        XCTAssertEqual(models.count, 1)
        XCTAssertTrue(models[0].isCloze)
    }

    // MARK: - Deck JSON parsing

    func testParseDecks() {
        let json = """
        {
          "1": {"id": 1, "name": "Default", "mod": 100},
          "1600000000": {"id": 1600000000, "name": "日本史::古代", "mod": 200}
        }
        """
        let decks = ApkgImporter.parseDecks(json)
        XCTAssertEqual(decks.count, 2)
        let nested = decks.first { $0.name == "日本史::古代" }
        XCTAssertNotNil(nested)
        XCTAssertEqual(nested?.displayName, "古代")
        XCTAssertEqual(nested?.depth, 1)
        XCTAssertEqual(nested?.parentName, "日本史")
    }

    // MARK: - Field separator

    func testNoteFieldSeparation() {
        let note = Note(id: 1, guid: "g", mid: 1, mod: 0,
                        tags: "tag1 tag2",
                        flds: "Front\u{1f}Back",
                        sfld: "Front")
        XCTAssertEqual(note.fieldValues, ["Front", "Back"])
        XCTAssertEqual(note.tagList, ["tag1", "tag2"])
    }

    func testFieldMapForNoteType() {
        let nt = NoteType(id: 1, name: "Basic",
                          fields: [NoteField(name: "Front", ord: 0), NoteField(name: "Back", ord: 1)],
                          templates: [],
                          css: "", type: 0)
        let note = Note(id: 1, guid: "g", mid: 1, mod: 0, tags: "",
                        flds: "表\u{1f}裏", sfld: "表")
        let map = note.fieldMap(for: nt)
        XCTAssertEqual(map["Front"], "表")
        XCTAssertEqual(map["Back"], "裏")
    }

    // MARK: - Database round-trip

    func testNoteTypePersistenceRoundTrip() throws {
        let db = try DatabaseManager.inMemory()
        let nt = NoteType(id: 42, name: "Basic",
                          fields: [NoteField(name: "Front", ord: 0), NoteField(name: "Back", ord: 1)],
                          templates: [CardTemplate(name: "C", ord: 0, qfmt: "{{Front}}", afmt: "{{Back}}")],
                          css: ".card{}", type: 0)
        try db.dbQueue.write { database in try nt.save(database) }

        let loaded = try db.noteType(id: 42)
        XCTAssertEqual(loaded?.name, "Basic")
        XCTAssertEqual(loaded?.orderedFieldNames, ["Front", "Back"])
        XCTAssertEqual(loaded?.templates.first?.qfmt, "{{Front}}")
    }

    func testCardPersistenceRoundTrip() throws {
        let db = try DatabaseManager.inMemory()
        let card = Card(id: 7, nid: 1, did: 1, ord: 0, type: 2, queue: 2, due: 5, ivl: 10, factor: 2500)
        try db.dbQueue.write { database in try card.save(database) }

        let loaded = try db.card(id: 7)
        XCTAssertEqual(loaded?.ivl, 10)
        XCTAssertEqual(loaded?.cardType, .review)
        XCTAssertEqual(loaded?.easeFactor ?? 0, 2.5, accuracy: 0.001)
    }

    func testDeckCountsByState() throws {
        let db = try DatabaseManager.inMemory()
        try db.dbQueue.write { database in
            try Deck(id: 1, name: "Test").save(database)
            try Card(id: 1, nid: 1, did: 1, ord: 0, type: 0, queue: 0, due: 0).save(database)
            try Card(id: 2, nid: 2, did: 1, ord: 0, type: 2, queue: 2, due: 0).save(database)
            try Card(id: 3, nid: 3, did: 1, ord: 0, type: 2, queue: 2, due: 100).save(database)
        }
        // todayDays = 0 → only the due=0 review card counts; the due=100 one does not.
        let counts = try db.counts(forDeckId: 1, todayCutoff: Int64(Date().timeIntervalSince1970), todayDays: 0)
        XCTAssertEqual(counts.new, 1)
        XCTAssertEqual(counts.review, 1)
    }
}
