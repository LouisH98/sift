import Foundation
import XCTest
@testable import Sift

final class DataRecoveryServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testBackupExistingFileCopiesContentAndAvoidsOverwriting() throws {
        let applicationSupportDirectory = try makeTemporaryDirectory()
        let service = DataRecoveryService(applicationSupportDirectory: applicationSupportDirectory)
        let sourceURL = applicationSupportDirectory.appendingPathComponent("thoughts.json")
        try "first".write(to: sourceURL, atomically: true, encoding: .utf8)

        let firstBackup = try XCTUnwrap(service.backupExistingFile(at: sourceURL, reason: .save))
        let secondBackup = try XCTUnwrap(service.backupExistingFile(at: sourceURL, reason: .save))

        XCTAssertNotEqual(firstBackup, secondBackup)
        XCTAssertEqual(try String(contentsOf: firstBackup, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: secondBackup, encoding: .utf8), "first")
        XCTAssertTrue(firstBackup.path.contains("/Recovery/Backups/thoughts/"))
    }

    func testQuarantineCorruptFileCopiesFileAndWritesMetadata() throws {
        let applicationSupportDirectory = try makeTemporaryDirectory()
        let service = DataRecoveryService(applicationSupportDirectory: applicationSupportDirectory)
        let sourceURL = applicationSupportDirectory.appendingPathComponent("pages.json")
        try "{not json".write(to: sourceURL, atomically: true, encoding: .utf8)

        let quarantineURL = try XCTUnwrap(service.quarantineCorruptFile(at: sourceURL, error: TestError.corrupt))
        let metadataURL = quarantineURL.appendingPathExtension("metadata.txt")

        XCTAssertEqual(try String(contentsOf: quarantineURL, encoding: .utf8), "{not json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8)
        XCTAssertTrue(metadata.contains("file: pages.json"))
        XCTAssertTrue(metadata.contains("error: corrupt"))
    }

    func testRestoreBacksUpExistingDestinationBeforeReplacingIt() throws {
        let applicationSupportDirectory = try makeTemporaryDirectory()
        let service = DataRecoveryService(applicationSupportDirectory: applicationSupportDirectory)
        let destinationURL = applicationSupportDirectory.appendingPathComponent("action-items.json")
        let sourceURL = applicationSupportDirectory.appendingPathComponent("replacement.json")
        try "old".write(to: destinationURL, atomically: true, encoding: .utf8)
        try "new".write(to: sourceURL, atomically: true, encoding: .utf8)

        try service.restoreDataFile(named: "action-items.json", from: sourceURL)

        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "new")

        let backupsURL = applicationSupportDirectory
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("action-items", isDirectory: true)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backupsURL.path)
        XCTAssertEqual(backupNames.count, 1)
        let backupURL = backupsURL.appendingPathComponent(try XCTUnwrap(backupNames.first))
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "old")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private enum TestError: Error, CustomStringConvertible {
        case corrupt

        var description: String {
            "corrupt"
        }
    }
}
