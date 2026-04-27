import Foundation
import Security

enum KeychainStore {
    private static let service = AppIdentity.bundleIdentifier

    static func string(for account: String) -> String {
        keychainString(for: account, service: service) ?? fileBackedString(for: account) ?? ""
    }

    static func set(_ value: String, for account: String) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            deleteKeychainString(for: account, service: service)
            deleteFileBackedString(for: account)
            return
        }

        if setKeychainString(trimmedValue, for: account, service: service) {
            deleteFileBackedString(for: account)
            return
        }

        setFileBackedString(trimmedValue, for: account)
    }

    private static func keychainString(for account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        return nil
    }

    private static func setKeychainString(_ value: String, for account: String, service: String) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return status == errSecSuccess
    }

    private static func deleteKeychainString(for account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]

        SecItemDelete(query as CFDictionary)
    }

    private static func fileBackedString(for account: String) -> String? {
        guard let data = try? Data(contentsOf: fileBackedURL(for: account)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private static func setFileBackedString(_ value: String, for account: String) {
        let url = fileBackedURL(for: account)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try Data(value.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            assertionFailure("Could not persist secret: \(error.localizedDescription)")
        }
    }

    private static func deleteFileBackedString(for account: String) {
        try? FileManager.default.removeItem(at: fileBackedURL(for: account))
    }

    private static func fileBackedURL(for account: String) -> URL {
        AppIdentity.applicationSupportDirectory()
            .appendingPathComponent("\(account).secret", isDirectory: false)
    }
}
