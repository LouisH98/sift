import XCTest
@testable import Sift

final class ThoughtModelDecodingTests: XCTestCase {
    func testActionItemMigratesLegacyDueAtIntoDateAndTime() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "thoughtID": "22222222-2222-2222-2222-222222222222",
          "title": "Send update",
          "isDone": false,
          "createdAt": "2026-04-29T09:00:00Z",
          "dueAt": "2026-05-01T14:30:00Z"
        }
        """.utf8)

        let item = try decoder.decode(ActionItem.self, from: data)
        let legacyDueAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-01T14:30:00Z"))
        let legacyComponents = Calendar.current.dateComponents([.hour, .minute], from: legacyDueAt)
        let expectedDueTime = String(
            format: "%02d:%02d",
            try XCTUnwrap(legacyComponents.hour),
            try XCTUnwrap(legacyComponents.minute)
        )

        XCTAssertEqual(item.dueTime, expectedDueTime)
        XCTAssertNotNil(item.dueDate)
        XCTAssertEqual(item.exactDueAt, item.sortDueAt)
    }

    func testActionItemTimeComponentsValidateClockTime() {
        XCTAssertEqual(ActionItem.timeComponents(from: "00:00")?.hour, 0)
        XCTAssertEqual(ActionItem.timeComponents(from: "23:59")?.minute, 59)
        XCTAssertNil(ActionItem.timeComponents(from: "24:00"))
        XCTAssertNil(ActionItem.timeComponents(from: "12:60"))
        XCTAssertNil(ActionItem.timeComponents(from: "9am"))
    }

    func testActionItemEncodingDoesNotWriteLegacyDueAt() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let item = ActionItem(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            thoughtID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            themeID: nil,
            title: "Send update",
            detail: nil,
            isDone: false,
            createdAt: Date(timeIntervalSince1970: 0),
            completedAt: nil,
            dueDate: Date(timeIntervalSince1970: 3_600),
            dueTime: "09:15"
        )

        let encoded = try encoder.encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(object["dueTime"] as? String, "09:15")
        XCTAssertNotNil(object["dueDate"])
        XCTAssertNil(object["dueAt"])
    }

    func testThoughtPageDecodingDefaultsMissingAliases() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = Data("""
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "title": "Research",
          "summary": "Notes",
          "bodyMarkdown": "- One",
          "tags": ["work"],
          "thoughtIDs": [],
          "createdAt": "2026-04-29T09:00:00Z",
          "updatedAt": "2026-04-29T10:00:00Z",
          "isStale": true
        }
        """.utf8)

        let page = try decoder.decode(ThoughtPage.self, from: data)

        XCTAssertEqual(page.aliases, [])
        XCTAssertEqual(page.title, "Research")
        XCTAssertTrue(page.isStale)
    }
}
