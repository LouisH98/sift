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
        static let providerKind = "ai.providerKind"
        static let apiBaseURL = "ai.apiBaseURL"
        static let apiEndpoint = "ai.apiEndpoint"
        static let modelID = "ai.modelID"
        static let apiKey = "openai.apiKey"
    }

    static let defaultAPIBaseURL = "https://api.openai.com/v1"
    static let defaultAPIEndpoint = APIEndpoint.responses
    static let defaultModelID = "gpt-5.4-mini"
    static let defaultProviderKind = ThoughtAIProviderKind.openAICompatible

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    @Published var providerKind: ThoughtAIProviderKind {
        didSet {
            UserDefaults.standard.set(providerKind.rawValue, forKey: Keys.providerKind)
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
        guard isEnabled else {
            return false
        }

        switch providerKind {
        case .openAICompatible:
            return URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .appleFoundationModels:
            return ThoughtAIProviderFactory.status(for: .appleFoundationModels).isAvailable
        }
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
        providerKind = UserDefaults.standard.string(forKey: Keys.providerKind)
            .flatMap(ThoughtAIProviderKind.init(rawValue:)) ?? Self.defaultProviderKind
        apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? Self.defaultAPIBaseURL
        apiEndpoint = UserDefaults.standard.string(forKey: Keys.apiEndpoint)
            .flatMap(APIEndpoint.init(rawValue:)) ?? Self.defaultAPIEndpoint
        modelID = UserDefaults.standard.string(forKey: Keys.modelID) ?? Self.defaultModelID
        apiKey = ""
    }
}

@MainActor
final class TodoSettings: ObservableObject {
    static let shared = TodoSettings()

    private enum Keys {
        static let remindersEnabled = "todo.remindersEnabled"
        static let reminderLeadTimeMinutes = "todo.reminderLeadTimeMinutes"
    }

    @Published var remindersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remindersEnabled, forKey: Keys.remindersEnabled)
        }
    }

    @Published var reminderLeadTimeMinutes: Int {
        didSet {
            let clamped = min(max(reminderLeadTimeMinutes, 0), 10_080)
            if reminderLeadTimeMinutes != clamped {
                reminderLeadTimeMinutes = clamped
                return
            }

            UserDefaults.standard.set(reminderLeadTimeMinutes, forKey: Keys.reminderLeadTimeMinutes)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        remindersEnabled = defaults.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        let storedLeadTime = defaults.object(forKey: Keys.reminderLeadTimeMinutes) as? Int
        reminderLeadTimeMinutes = storedLeadTime ?? 60
    }
}
