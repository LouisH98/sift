import XCTest
@testable import Sift

final class ThoughtPrefixParserTests: XCTestCase {
    func testThemeHintParsesLeadingThemePrefix() {
        let hint = ThoughtPrefixParser.themeHint(in: "Work: Draft launch notes")

        XCTAssertEqual(hint?.title, "Work")
        XCTAssertEqual(hint?.prefixLength, "Work:".count)
    }

    func testThemeHintParsesAfterTodoPrefix() {
        let hint = ThoughtPrefixParser.themeHint(in: "! Inbox: Reply to Sam")

        XCTAssertEqual(hint?.title, "Inbox")
        XCTAssertEqual(hint?.prefixLength, "! Inbox:".count)
    }

    func testThemeHintRejectsSentencePunctuationBeforeColon() {
        XCTAssertNil(ThoughtPrefixParser.themeHint(in: "Can this work?: maybe"))
    }

    func testTodoBodyRemovesTodoAndThemePrefixes() {
        XCTAssertEqual(
            ThoughtPrefixParser.todoBody(in: "! Work: Draft launch notes"),
            "Draft launch notes"
        )
    }

    func testTodoDirectiveBodyRemovesNestedTodoPrefixes() {
        XCTAssertEqual(
            ThoughtPrefixParser.todoDirectiveBody(in: "Work: ! ! Draft launch notes"),
            "Draft launch notes"
        )
    }
}
