import Foundation

enum ThoughtAIProviderKind: String, CaseIterable, Identifiable {
    case openAICompatible
    case appleFoundationModels

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI-compatible"
        case .appleFoundationModels:
            "Apple Foundation Models"
        }
    }
}

struct ThoughtAIProviderStatus {
    let title: String
    let message: String
    let isAvailable: Bool
}

enum ThoughtAIProviderError: LocalizedError {
    case unavailable(String)
    case unsupported(String)
    case blockedBySafety
    case unsupportedLanguageOrLocale(String)
    case contextTooLarge
    case rateLimited
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .unsupported(let message):
            message
        case .blockedBySafety:
            "Apple Foundation Models blocked this request with its safety guardrails. Try a shorter, more neutral prompt or edit the thought text."
        case .unsupportedLanguageOrLocale(let locale):
            "Apple Foundation Models could not handle the language or locale for this request (\(locale)). Try editing the thought text to English, or use the OpenAI-compatible provider."
        case .contextTooLarge:
            "Apple Foundation Models could not fit this request in its local context window. Try fewer thoughts or a smaller notebook section."
        case .rateLimited:
            "Apple Foundation Models is temporarily rate-limited. Wait a moment and try again."
        case .generationFailed(let message):
            "Apple Foundation Models generation failed: \(message)"
        }
    }
}

@MainActor
protocol ThoughtAIProvider {
    func process(input: ThoughtProcessingInput) async throws -> ThoughtProcessingOutput
    func reorganize(input: ThoughtReorganizationInput) async throws -> ReorganizationProposal
    func synthesizePage(input: ThoughtSynthesisInput) async throws -> ThoughtSynthesisOutput
    func generateRawText(instructions: String, prompt: String) async throws -> String
    func streamRawText(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error>
    func suggestTags(for text: String) async throws -> [String]
    func prewarm()
}

@MainActor
enum ThoughtAIProviderFactory {
    static func provider(settings: AISettings, store: ThoughtStore) -> any ThoughtAIProvider {
        switch settings.providerKind {
        case .openAICompatible:
            return OpenAIClient(settings: settings)
        case .appleFoundationModels:
            return AppleFoundationModelsProviderFactory.makeProvider(store: store)
        }
    }

    static func status(for kind: ThoughtAIProviderKind) -> ThoughtAIProviderStatus {
        switch kind {
        case .openAICompatible:
            ThoughtAIProviderStatus(
                title: "OpenAI-compatible provider",
                message: "Uses the configured API endpoint, key, and model.",
                isAvailable: true
            )
        case .appleFoundationModels:
            AppleFoundationModelsProviderFactory.status()
        }
    }
}

@MainActor
enum AppleFoundationModelsProviderFactory {
    static func makeProvider(store: ThoughtStore) -> any ThoughtAIProvider {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsProvider(store: store)
        }
        #endif

        return UnavailableAppleFoundationModelsProvider()
    }

    static func status() -> ThoughtAIProviderStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsProvider.status()
        }
        #endif

        return ThoughtAIProviderStatus(
            title: "Foundation Models unavailable",
            message: "Apple Foundation Models requires the macOS 26 SDK/runtime and Apple Intelligence support.",
            isAvailable: false
        )
    }
}

@MainActor
private struct UnavailableAppleFoundationModelsProvider: ThoughtAIProvider {
    private let message = "Apple Foundation Models is unavailable on this Mac or SDK."

    func process(input: ThoughtProcessingInput) async throws -> ThoughtProcessingOutput {
        throw ThoughtAIProviderError.unavailable(message)
    }

    func reorganize(input: ThoughtReorganizationInput) async throws -> ReorganizationProposal {
        throw ThoughtAIProviderError.unavailable(message)
    }

    func synthesizePage(input: ThoughtSynthesisInput) async throws -> ThoughtSynthesisOutput {
        throw ThoughtAIProviderError.unavailable(message)
    }

    func generateRawText(instructions: String, prompt: String) async throws -> String {
        throw ThoughtAIProviderError.unavailable(message)
    }

    func streamRawText(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ThoughtAIProviderError.unavailable(message))
        }
    }

    func suggestTags(for text: String) async throws -> [String] {
        throw ThoughtAIProviderError.unavailable(message)
    }

    func prewarm() {}
}
