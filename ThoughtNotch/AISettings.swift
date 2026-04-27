import Combine
import Foundation

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    enum APIEndpoint: String, CaseIterable, Identifiable {
        case responses
        case chatCompletions

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .responses:
                "Responses API"
            case .chatCompletions:
                "Chat Completions"
            }
        }
    }

    private enum Keys {
        static let isEnabled = "ai.isEnabled"
        static let apiBaseURL = "ai.apiBaseURL"
        static let apiEndpoint = "ai.apiEndpoint"
        static let modelID = "ai.modelID"
        static let apiKey = "openai.apiKey"
    }

    static let defaultAPIBaseURL = "https://api.openai.com/v1"
    static let defaultAPIEndpoint = APIEndpoint.responses
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

    @Published var apiEndpoint: APIEndpoint {
        didSet {
            UserDefaults.standard.set(apiEndpoint.rawValue, forKey: Keys.apiEndpoint)
        }
    }

    @Published var modelID: String {
        didSet {
            UserDefaults.standard.set(modelID, forKey: Keys.modelID)
        }
    }

    @Published var apiKey: String {
        didSet {
            guard !isLoadingAPIKey else {
                return
            }

            KeychainStore.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.apiKey)
        }
    }

    private var hasLoadedAPIKey = false
    private var isLoadingAPIKey = false

    var canProcess: Bool {
        isEnabled && URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    @discardableResult
    func loadAPIKeyIfNeeded() -> String {
        guard !hasLoadedAPIKey else {
            return apiKey
        }

        let storedAPIKey = KeychainStore.string(for: Keys.apiKey)
        hasLoadedAPIKey = true

        guard apiKey != storedAPIKey else {
            return apiKey
        }

        isLoadingAPIKey = true
        apiKey = storedAPIKey
        isLoadingAPIKey = false

        return apiKey
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? Self.defaultAPIBaseURL
        apiEndpoint = UserDefaults.standard.string(forKey: Keys.apiEndpoint)
            .flatMap(APIEndpoint.init(rawValue:)) ?? Self.defaultAPIEndpoint
        modelID = UserDefaults.standard.string(forKey: Keys.modelID) ?? Self.defaultModelID
        apiKey = ""
    }
}
