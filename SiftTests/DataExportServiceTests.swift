import Foundation
import XCTest
@testable import Sift

@MainActor
final class DataExportServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testExportWritesBundleAndMarkdownToChosenDirectory() throws {
        let destinationDirectory = try makeTemporaryDirectory()
        let service = DataExportService(applicationSupportDirectory: try makeTemporaryDirectory())
        let bundle = makeExportBundle()

        let result = try service.export(bundle: bundle, to: destinationDirectory)

        XCTAssertEqual(result.folderURL.deletingLastPathComponent(), destinationDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.pagesMarkdownURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.thoughtsMarkdownURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.todosMarkdownURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportedBundle = try decoder.decode(SiftDataExportBundle.self, from: Data(contentsOf: result.bundleURL))

        XCTAssertEqual(exportedBundle.schemaVersion, 1)
        XCTAssertEqual(exportedBundle.thoughts.map(\.text), ["Ship picker export"])
        XCTAssertEqual(exportedBundle.pages.map(\.title), ["Privacy"])
        XCTAssertEqual(exportedBundle.actionItems.map(\.title), ["Add tests"])

        let pagesMarkdown = try String(contentsOf: result.pagesMarkdownURL, encoding: .utf8)
        let thoughtsMarkdown = try String(contentsOf: result.thoughtsMarkdownURL, encoding: .utf8)
        let todosMarkdown = try String(contentsOf: result.todosMarkdownURL, encoding: .utf8)

        XCTAssertTrue(pagesMarkdown.contains("# Sift Pages"))
        XCTAssertTrue(pagesMarkdown.contains("## Privacy"))
        XCTAssertTrue(thoughtsMarkdown.contains("# Sift Thoughts"))
        XCTAssertTrue(thoughtsMarkdown.contains("Ship picker export"))
        XCTAssertTrue(todosMarkdown.contains("# Sift Todos"))
        XCTAssertTrue(todosMarkdown.contains("[ ] Add tests"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeExportBundle() -> SiftDataExportBundle {
        let thoughtID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let pageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let actionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let exportedAt = Date(timeIntervalSince1970: 1_800)
        let createdAt = Date(timeIntervalSince1970: 1_000)

        return SiftDataExportBundle(
            schemaVersion: 1,
            exportedAt: exportedAt,
            thoughts: [
                Thought(
                    id: thoughtID,
                    text: "Ship picker export",
                    createdAt: createdAt,
                    distilled: "Use a user-selected folder for exports.",
                    title: "Picker export",
                    tags: ["privacy"],
                    category: "Privacy",
                    pageID: pageID
                )
            ],
            themes: [],
            pages: [
                ThoughtPage(
                    id: pageID,
                    parentID: nil,
                    title: "Privacy",
                    summary: "Permission notes",
                    bodyMarkdown: "- Prefer pickers",
                    synthesisMarkdown: nil,
                    synthesizedAt: nil,
                    synthesisSourceHash: nil,
                    tags: ["app"],
                    thoughtIDs: [thoughtID],
                    colorHex: nil,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    isStale: false
                )
            ],
            dailyDigests: [],
            actionItems: [
                ActionItem(
                    id: actionID,
                    thoughtID: thoughtID,
                    themeID: pageID,
                    title: "Add tests",
                    detail: "Cover export output",
                    isDone: false,
                    createdAt: createdAt,
                    completedAt: nil,
                    dueDate: nil,
                    dueTime: nil
                )
            ]
        )
    }
}
