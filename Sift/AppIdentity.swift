import Foundation

enum AppIdentity {
    static let name = "Sift"
    static let bundleIdentifier = "com.louis.Sift"

    static func applicationSupportDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }
}
