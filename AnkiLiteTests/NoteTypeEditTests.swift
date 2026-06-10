import XCTest
@testable import AnkiLite

final class NoteTypeEditTests: XCTestCase {

    func testRenameFieldReferencesCoversAllSyntaxes() {
        let template = "{{表面}} {{#表面}}x{{/表面}} {{^表面}}y{{/表面}} {{cloze:表面}} {{hint:type:表面}} {{裏面}}"
        let out = NoteTypeEditView.renameFieldReferences(in: template, from: "表面", to: "Front")
        XCTAssertEqual(out,
            "{{Front}} {{#Front}}x{{/Front}} {{^Front}}y{{/Front}} {{cloze:Front}} {{hint:type:Front}} {{裏面}}")
    }

    func testRenameDoesNotTouchSupersetNames() {
        // Renaming "Back" must not corrupt "{{Back Extra}}".
        let template = "{{Back}} {{Back Extra}}"
        let out = NoteTypeEditView.renameFieldReferences(in: template, from: "Back", to: "裏")
        XCTAssertEqual(out, "{{裏}} {{Back Extra}}")
    }
}
