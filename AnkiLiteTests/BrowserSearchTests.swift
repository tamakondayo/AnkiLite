import XCTest
@testable import AnkiLite

final class BrowserSearchTests: XCTestCase {

    private var context: BrowserSearch.Context {
        BrowserSearch.Context(
            scopeDecks: [
                Deck(id: 1, name: "英語"),
                Deck(id: 2, name: "英語::TOEIC"),
                Deck(id: 3, name: "日本史")
            ],
            todayDays: 100,
            nowCutoff: 1_700_000_000
        )
    }

    // MARK: - Tokenizer

    func testTokenizeQuotedPhrasesAndPrefixes() {
        XCTAssertEqual(BrowserSearch.tokenize(#"hello "two words" deck:"My Deck" tag:x"#),
                       ["hello", "two words", "deck:My Deck", "tag:x"])
        // Full-width spaces split too.
        XCTAssertEqual(BrowserSearch.tokenize("犬\u{3000}猫"), ["犬", "猫"])
    }

    // MARK: - LIKE escaping

    func testLikePatternEscapesMetacharacters() {
        XCTAssertEqual(BrowserSearch.likePattern("50%_a\\b"), "%50\\%\\_a\\\\b%")
        XCTAssertEqual(BrowserSearch.likePattern("wo*rd"), "%wo%rd%")
    }

    // MARK: - Compile

    func testPlainTermSearchesFieldsSortFieldAndTags() {
        let compiled = BrowserSearch.compile(query: "犬", context: context)
        XCTAssertTrue(compiled.sqlFragment.contains("note.flds LIKE ? ESCAPE"))
        XCTAssertEqual(compiled.arguments.count, 3)
        XCTAssertEqual(compiled.arguments[0] as? String, "%犬%")
    }

    func testDeckTermResolvesToScopedDeckIds() {
        let compiled = BrowserSearch.compile(query: "deck:TOEIC", context: context)
        XCTAssertTrue(compiled.sqlFragment.contains("card.did IN (2)"),
                      "deck:TOEIC should resolve to the TOEIC subdeck id")
    }

    func testDeckTermWithNoMatchMatchesNothing() {
        let compiled = BrowserSearch.compile(query: "deck:数学", context: context)
        XCTAssertTrue(compiled.sqlFragment.contains("(0)"),
                      "An unknown deck must produce a never-true clause")
    }

    func testIsNewAndNegation() {
        let positive = BrowserSearch.compile(query: "is:new", context: context)
        XCTAssertTrue(positive.sqlFragment.contains("card.queue = 0"))

        let negative = BrowserSearch.compile(query: "-is:new", context: context)
        XCTAssertTrue(negative.sqlFragment.contains("NOT (card.queue = 0)"))
    }

    func testFlagTermBounds() {
        XCTAssertTrue(BrowserSearch.compile(query: "flag:3", context: context)
            .sqlFragment.contains("(card.flags & 7) = 3"))
        // Out-of-range flag is ignored rather than crashing.
        XCTAssertEqual(BrowserSearch.compile(query: "flag:9", context: context).sqlFragment, "")
    }

    func testTagTermMatchesSubtags() {
        let compiled = BrowserSearch.compile(query: "tag:vocab", context: context)
        XCTAssertEqual(compiled.arguments.count, 2)
        XCTAssertEqual(compiled.arguments[0] as? String, "% vocab %")
        XCTAssertEqual(compiled.arguments[1] as? String, "% vocab::%")
    }

    func testTermsAreANDed() {
        let compiled = BrowserSearch.compile(query: "is:review flag:1", context: context)
        XCTAssertTrue(compiled.sqlFragment.contains("card.queue = 2"))
        XCTAssertTrue(compiled.sqlFragment.contains("(card.flags & 7) = 1"))
    }
}
