import XCTest
@testable import AnkiLite

final class AnkiTemplateRendererTests: XCTestCase {

    private func basicNoteType() -> NoteType {
        NoteType(
            id: 1,
            name: "Basic",
            fields: [NoteField(name: "Front", ord: 0), NoteField(name: "Back", ord: 1)],
            templates: [CardTemplate(name: "Card 1", ord: 0,
                                     qfmt: "{{Front}}",
                                     afmt: "{{FrontSide}}<hr id=answer>{{Back}}")],
            css: "",
            type: 0
        )
    }

    private func clozeNoteType() -> NoteType {
        NoteType(
            id: 2,
            name: "Cloze",
            fields: [NoteField(name: "Text", ord: 0), NoteField(name: "Extra", ord: 1)],
            templates: [CardTemplate(name: "Cloze", ord: 0,
                                     qfmt: "{{cloze:Text}}",
                                     afmt: "{{cloze:Text}}<br>{{Extra}}")],
            css: "",
            type: 1
        )
    }

    private func note(_ values: [String], mid: Int64) -> Note {
        Note(id: 1, guid: "g", mid: mid, mod: 0,
             tags: "", flds: values.joined(separator: ankiFieldSeparator), sfld: values.first ?? "")
    }

    func testBasicFieldSubstitution() {
        let nt = basicNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["こんにちは", "Hello"], mid: 1)

        let front = renderer.render(note: n, ord: 0, side: .question)
        XCTAssertEqual(front, "こんにちは")
    }

    func testFrontSideSubstitution() {
        let nt = basicNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["こんにちは", "Hello"], mid: 1)

        let front = renderer.render(note: n, ord: 0, side: .question)
        let back = renderer.render(note: n, ord: 0, side: .answer, frontSide: front)
        XCTAssertTrue(back.contains("こんにちは"))
        XCTAssertTrue(back.contains("Hello"))
        XCTAssertTrue(back.contains("<hr id=answer>"))
    }

    func testConditionalShownWhenNotEmpty() {
        let nt = NoteType(id: 3, name: "Cond",
                          fields: [NoteField(name: "A", ord: 0), NoteField(name: "B", ord: 1)],
                          templates: [CardTemplate(name: "C", ord: 0,
                                                   qfmt: "{{A}}{{#B}} [{{B}}]{{/B}}",
                                                   afmt: "{{A}}")],
                          css: "", type: 0)
        let renderer = AnkiTemplateRenderer(noteType: nt)

        let withB = renderer.render(note: note(["a", "b"], mid: 3), ord: 0, side: .question)
        XCTAssertEqual(withB, "a [b]")

        let withoutB = renderer.render(note: note(["a", ""], mid: 3), ord: 0, side: .question)
        XCTAssertEqual(withoutB, "a")
    }

    func testNegativeConditional() {
        let nt = NoteType(id: 4, name: "Neg",
                          fields: [NoteField(name: "A", ord: 0), NoteField(name: "B", ord: 1)],
                          templates: [CardTemplate(name: "C", ord: 0,
                                                   qfmt: "{{A}}{{^B}} (no b){{/B}}",
                                                   afmt: "{{A}}")],
                          css: "", type: 0)
        let renderer = AnkiTemplateRenderer(noteType: nt)

        let withoutB = renderer.render(note: note(["a", ""], mid: 4), ord: 0, side: .question)
        XCTAssertEqual(withoutB, "a (no b)")

        let withB = renderer.render(note: note(["a", "b"], mid: 4), ord: 0, side: .question)
        XCTAssertEqual(withB, "a")
    }

    func testClozeQuestionHidesActiveCloze() {
        let nt = clozeNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["The {{c1::sun}} is a {{c2::star}}.", ""], mid: 2)

        // ord 0 → cloze number 1 is active.
        let q = renderer.render(note: n, ord: 0, side: .question)
        XCTAssertTrue(q.contains("[...]"), "active cloze should be hidden: \(q)")
        XCTAssertTrue(q.contains("star"), "inactive cloze answer should be shown: \(q)")
        XCTAssertFalse(q.contains("sun"))
    }

    func testClozeAnswerRevealsActiveCloze() {
        let nt = clozeNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["The {{c1::sun}} is a {{c2::star}}.", ""], mid: 2)

        let a = renderer.render(note: n, ord: 0, side: .answer,
                                frontSide: renderer.render(note: n, ord: 0, side: .question))
        XCTAssertTrue(a.contains("class=\"cloze\">sun</span>"), a)
        XCTAssertTrue(a.contains("star"))
    }

    func testClozeWithHint() {
        let nt = clozeNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["Capital is {{c1::Paris::city}}.", ""], mid: 2)

        let q = renderer.render(note: n, ord: 0, side: .question)
        XCTAssertTrue(q.contains("[city]"), q)
    }

    func testSecondClozeCardUsesOrd1() {
        let nt = clozeNoteType()
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["The {{c1::sun}} is a {{c2::star}}.", ""], mid: 2)

        // ord 1 → cloze number 2 is active.
        let q = renderer.render(note: n, ord: 1, side: .question)
        XCTAssertTrue(q.contains("sun"))
        XCTAssertTrue(q.contains("[...]"))
        XCTAssertFalse(q.contains("star"))
    }

    func testSoundTagConversion() {
        let nt = NoteType(id: 5, name: "S",
                          fields: [NoteField(name: "A", ord: 0)],
                          templates: [CardTemplate(name: "C", ord: 0, qfmt: "{{A}}", afmt: "{{A}}")],
                          css: "", type: 0)
        let renderer = AnkiTemplateRenderer(noteType: nt)
        let n = note(["[sound:hello.mp3]"], mid: 5)

        let q = renderer.render(note: n, ord: 0, side: .question)
        XCTAssertTrue(q.contains("<audio"))
        XCTAssertTrue(q.contains("hello.mp3"))
        XCTAssertFalse(q.contains("[sound:"))
    }
}
