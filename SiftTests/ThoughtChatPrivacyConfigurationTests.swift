import XCTest
@testable import Sift

final class ThoughtChatPrivacyConfigurationTests: XCTestCase {
    func testWebSearchToolIsAbsentByDefault() {
        let tools = ThoughtChatAgentConfiguration.tools(isWebSearchEnabled: false)

        XCTAssertFalse(tools.contains { $0["type"] as? String == "web_search" })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "search_notes" })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "search_actions" })
    }

    func testWebSearchToolIsOnlyAddedWhenEnabled() {
        let tools = ThoughtChatAgentConfiguration.tools(isWebSearchEnabled: true)

        XCTAssertEqual(tools.first?["type"] as? String, "web_search")
        XCTAssertEqual(tools.filter { $0["type"] as? String == "web_search" }.count, 1)
    }

    func testWebSearchInstructionReflectsPrivacyToggle() {
        let disabledInstruction = ThoughtChatAgentConfiguration.webSearchInstruction(isWebSearchEnabled: false)
        let enabledInstruction = ThoughtChatAgentConfiguration.webSearchInstruction(isWebSearchEnabled: true)

        XCTAssertTrue(disabledInstruction.contains("Web search is not available"))
        XCTAssertTrue(disabledInstruction.contains("local Sift tools"))
        XCTAssertTrue(enabledInstruction.contains("Web search is available"))
        XCTAssertTrue(enabledInstruction.contains("explicitly asks"))
        XCTAssertTrue(enabledInstruction.contains("private"))
    }
}
