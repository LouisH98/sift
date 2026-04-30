import Foundation

enum SiftDataRecoveryReason: String {
    case save
    case restore
    case quarantine
}

struct DataRecoveryService {
    static let shared = DataRecoveryService()

    let applicationSupportDirectory: URL

    private var recoveryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    private var backupsDirectory: URL {
        recoveryDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    private var quarantineDirectory: URL {
        recoveryDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    init(applicationSupportDirectory: URL = AppIdentity.applicationSupportDirectory()) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    @discardableResult
    func backupExistingFile(at url: URL, reason: SiftDataRecoveryReason) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let backupFolder = backupsDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        let destination = uniqueRecoveryURL(
            in: backupFolder,
            baseName: "\(timestamp())-\(reason.rawValue)",
            originalFileName: url.lastPathComponent
        )
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    func quarantineCorruptFile(at url: URL, error: Error) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let destination = uniqueRecoveryURL(
            in: quarantineDirectory,
            baseName: "\(timestamp())-\(url.deletingPathExtension().lastPathComponent)",
            originalFileName: url.lastPathComponent
        )

        try fileManager.copyItem(at: url, to: destination)
        let metadataURL = destination.appendingPathExtension("metadata.txt")
        let metadata = """
        file: \(url.lastPathComponent)
        quarantinedAt: \(ISO8601DateFormatter().string(from: Date()))
        error: \(error)
        """
        try metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
        return destination
    }

    func restoreDataFile(named fileName: String, from sourceURL: URL) throws {
        let destinationURL = applicationSupportDirectory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try backupExistingFile(at: destinationURL, reason: .restore)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func uniqueRecoveryURL(in directory: URL, baseName: String, originalFileName: String) -> URL {
        let sanitizedOriginalName = sanitizedFileComponent(originalFileName)
        let baseURL = directory.appendingPathComponent("\(baseName)-\(sanitizedOriginalName)")
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName)-\(index)-\(sanitizedOriginalName)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func timestamp() -> String {
        Self.timestampFormatter.string(from: Date())
    }

    private func sanitizedFileComponent(_ value: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars
            .map { allowedCharacters.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
