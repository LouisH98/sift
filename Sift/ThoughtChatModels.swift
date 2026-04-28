import Combine
import Foundation

enum ThoughtChatRole: String, Codable {
    case user
    case assistant
}

struct ThoughtChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: ThoughtChatRole
    var text: String
    var sources: [ThoughtChatSource]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ThoughtChatRole,
        text: String,
        sources: [ThoughtChatSource] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.sources = sources
        self.createdAt = createdAt
    }
}

struct ThoughtChatSource: Identifiable, Hashable {
    enum Kind: String {
        case thought
        case page
    }

    let id: UUID
    let kind: Kind
    let title: String
    let snippet: String
    let date: Date?
    let score: Double

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return kind == .thought ? "Thought" : "Page"
        }

        return trimmedTitle
    }
}

enum ThoughtChatUpdate {
    case partialAnswer(String)
    case finalSources([ThoughtChatSource])
}

@MainActor
final class ThoughtChatModel: ObservableObject {
    @Published var draft = ""
    @Published var messages: [ThoughtChatMessage] = []
    @Published var isAsking = false
    @Published var errorMessage: String?

    private var activeTask: Task<Void, Never>?
    private let service: ThoughtChatService

    init(service: ThoughtChatService = ThoughtChatService()) {
        self.service = service
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAsking
    }

    func ask(store: ThoughtStore, settings: AISettings) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else {
            return
        }

        activeTask?.cancel()
        draft = ""
        errorMessage = nil
        isAsking = true

        let userMessage = ThoughtChatMessage(role: .user, text: question)
        let assistantID = UUID()
        messages.append(userMessage)
        messages.append(ThoughtChatMessage(id: assistantID, role: .assistant, text: ""))

        let history = messages
        activeTask = Task { [weak self, service] in
            var accumulatedText = ""
            var finalSources: [ThoughtChatSource] = []

            do {
                for try await update in service.ask(question: question, history: history, store: store, settings: settings) {
                    guard !Task.isCancelled else {
                        return
                    }

                    switch update {
                    case .partialAnswer(let text):
                        accumulatedText = text
                        self?.updateAssistantMessage(id: assistantID, text: text, sources: finalSources)
                    case .finalSources(let sources):
                        finalSources = sources
                        self?.updateAssistantMessage(id: assistantID, text: accumulatedText, sources: sources)
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                let fallbackSources = service.sources(for: question, store: store)
                let fallbackText = accumulatedText.isEmpty ? "I could not answer from your thoughts right now." : accumulatedText
                self?.updateAssistantMessage(id: assistantID, text: fallbackText, sources: fallbackSources)
                self?.errorMessage = error.localizedDescription
            }

            self?.isAsking = false
            self?.activeTask = nil
        }
    }

    func cancelRequest() {
        activeTask?.cancel()
        activeTask = nil
        isAsking = false
    }

    func resetSession() {
        cancelRequest()
        draft = ""
        messages = []
        errorMessage = nil
    }

    private func updateAssistantMessage(id: UUID, text: String, sources: [ThoughtChatSource]) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        messages[index].text = text
        messages[index].sources = sources
    }
}
