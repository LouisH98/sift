import Combine
import Foundation

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    private enum Keys {
        static let isEnabled = "ai.isEnabled"
        static let apiBaseURL = "ai.apiBaseURL"
        static let modelID = "ai.modelID"
        static let apiKey = "openai.apiKey"
    }

    static let defaultAPIBaseURL = "https://api.openai.com/v1"
    static let defaultModelID = "gpt-5.4-mini"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            UserDefaults.standard.set(apiBaseURL, forKey: Keys.apiBaseURL)
        }
    }

    @Published var modelID: String {
        didSet {
            UserDefaults.standard.set(modelID, forKey: Keys.modelID)
        }
    }

    @Published var apiKey: String {
        didSet {
            KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.apiKey)
        }
    }

    var canProcess: Bool {
        isEnabled && URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? Self.defaultAPIBaseURL
        modelID = UserDefaults.standard.string(forKey: Keys.modelID) ?? Self.defaultModelID
        apiKey = KeychainStore.string(for: Keys.apiKey)
    }
}
