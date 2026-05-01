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

    enum APIKeySource: String, CaseIterable, Identifiable {
        case manual
        case environmentVariable

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .manual:
                "API key"
            case .environmentVariable:
                "Env var"
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
        static let apiKeySource = "openai.apiKeySource"
        static let apiKeyEnvironmentVariableName = "openai.apiKeyEnvironmentVariableName"
        static let isChatWebSearchEnabled = "ai.chatWebSearchEnabled"
    }

    static let defaultAPIBaseURL = "https://api.openai.com/v1"
    static let defaultAPIEndpoint = APIEndpoint.responses
    static let defaultModelID = "gpt-5.4-mini"
    static let defaultProviderKind = ThoughtAIProviderKind.openAICompatible
    static let defaultAPIKeyEnvironmentVariableName = "OPENAI_API_KEY"

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

    @Published var apiKeySource: APIKeySource {
        didSet {
            UserDefaults.standard.set(apiKeySource.rawValue, forKey: Keys.apiKeySource)
            if apiKeySource != .environmentVariable {
                clearShellEnvironmentAPIKey()
            }
        }
    }

    @Published var apiKeyEnvironmentVariableName: String {
        didSet {
            UserDefaults.standard.set(apiKeyEnvironmentVariableName, forKey: Keys.apiKeyEnvironmentVariableName)
            if apiKeyEnvironmentVariableName != oldValue {
                clearShellEnvironmentAPIKey()
            }
        }
    }

    @Published private(set) var isLoadingShellEnvironmentAPIKey = false
    @Published private(set) var shellEnvironmentAPIKeyMessage: String?
    @Published private(set) var shellEnvironmentAPIKeyError: String?

    @Published var isChatWebSearchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isChatWebSearchEnabled, forKey: Keys.isChatWebSearchEnabled)
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
    private var shellEnvironmentAPIKey = ""
    private var loadedShellEnvironmentAPIKeyName: String?

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

    func resolvedAPIKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        switch apiKeySource {
        case .manual:
            return Self.resolvedAPIKey(
                source: .manual,
                manualAPIKey: loadAPIKeyIfNeeded(),
                environmentVariableName: apiKeyEnvironmentVariableName,
                environment: environment
            )
        case .environmentVariable:
            let processEnvironmentAPIKey = Self.resolvedAPIKey(
                source: .environmentVariable,
                manualAPIKey: "",
                environmentVariableName: apiKeyEnvironmentVariableName,
                environment: environment
            )
            return processEnvironmentAPIKey.isEmpty ? shellEnvironmentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) : processEnvironmentAPIKey
        }
    }

    static func resolvedAPIKey(
        source: APIKeySource,
        manualAPIKey: String,
        environmentVariableName: String,
        environment: [String: String]
    ) -> String {
        switch source {
        case .manual:
            return manualAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .environmentVariable:
            let key = environmentVariableName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return ""
            }

            return environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    func loadEnvironmentAPIKeyFromShellIfNeeded(force: Bool = false) async {
        guard apiKeySource == .environmentVariable else {
            clearShellEnvironmentAPIKey()
            return
        }

        let variableName = apiKeyEnvironmentVariableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShellEnvironmentReader.isValidEnvironmentVariableName(variableName) else {
            isLoadingShellEnvironmentAPIKey = false
            shellEnvironmentAPIKey = ""
            loadedShellEnvironmentAPIKeyName = nil
            shellEnvironmentAPIKeyMessage = nil
            shellEnvironmentAPIKeyError = "Enter a valid environment variable name."
            return
        }

        if !force, loadedShellEnvironmentAPIKeyName == variableName {
            return
        }

        let processEnvironmentAPIKey = Self.resolvedAPIKey(
            source: .environmentVariable,
            manualAPIKey: "",
            environmentVariableName: variableName,
            environment: ProcessInfo.processInfo.environment
        )

        if !processEnvironmentAPIKey.isEmpty {
            isLoadingShellEnvironmentAPIKey = false
            shellEnvironmentAPIKey = processEnvironmentAPIKey
            loadedShellEnvironmentAPIKeyName = variableName
            shellEnvironmentAPIKeyMessage = "Loaded \(variableName) from the app environment."
            shellEnvironmentAPIKeyError = nil
            return
        }

        isLoadingShellEnvironmentAPIKey = true
        shellEnvironmentAPIKeyMessage = nil
        shellEnvironmentAPIKeyError = nil

        do {
            let apiKey = try await ShellEnvironmentReader().readValue(named: variableName)
            guard apiKeySource == .environmentVariable,
                  apiKeyEnvironmentVariableName.trimmingCharacters(in: .whitespacesAndNewlines) == variableName else {
                return
            }

            shellEnvironmentAPIKey = apiKey
            loadedShellEnvironmentAPIKeyName = variableName
            shellEnvironmentAPIKeyMessage = "Loaded \(variableName) from your login shell."
        } catch {
            guard apiKeySource == .environmentVariable,
                  apiKeyEnvironmentVariableName.trimmingCharacters(in: .whitespacesAndNewlines) == variableName else {
                return
            }

            shellEnvironmentAPIKey = ""
            loadedShellEnvironmentAPIKeyName = nil
            shellEnvironmentAPIKeyError = error.localizedDescription
        }

        isLoadingShellEnvironmentAPIKey = false
    }

    private func clearShellEnvironmentAPIKey() {
        shellEnvironmentAPIKey = ""
        loadedShellEnvironmentAPIKeyName = nil
        isLoadingShellEnvironmentAPIKey = false
        shellEnvironmentAPIKeyMessage = nil
        shellEnvironmentAPIKeyError = nil
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        providerKind = UserDefaults.standard.string(forKey: Keys.providerKind)
            .flatMap(ThoughtAIProviderKind.init(rawValue:)) ?? Self.defaultProviderKind
        apiBaseURL = UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? Self.defaultAPIBaseURL
        apiEndpoint = UserDefaults.standard.string(forKey: Keys.apiEndpoint)
            .flatMap(APIEndpoint.init(rawValue:)) ?? Self.defaultAPIEndpoint
        modelID = UserDefaults.standard.string(forKey: Keys.modelID) ?? Self.defaultModelID
        apiKeySource = UserDefaults.standard.string(forKey: Keys.apiKeySource)
            .flatMap(APIKeySource.init(rawValue:)) ?? .manual
        apiKeyEnvironmentVariableName = UserDefaults.standard.string(forKey: Keys.apiKeyEnvironmentVariableName)
            ?? Self.defaultAPIKeyEnvironmentVariableName
        isChatWebSearchEnabled = UserDefaults.standard.bool(forKey: Keys.isChatWebSearchEnabled)
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
