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
    var responseID: String?
    var sources: [ThoughtChatSource]
    var proposedActions: [ThoughtChatProposedAction]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ThoughtChatRole,
        text: String,
        responseID: String? = nil,
        sources: [ThoughtChatSource] = [],
        proposedActions: [ThoughtChatProposedAction] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.responseID = responseID
        self.sources = sources
        self.proposedActions = proposedActions
        self.createdAt = createdAt
    }
}

struct ThoughtChatSource: Identifiable, Hashable {
    enum Kind: String {
        case thought
        case page
        case actionItem
        case web
    }

    let id: UUID
    let kind: Kind
    let title: String
    let snippet: String
    let date: Date?
    let score: Double
    let url: URL?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        snippet: String,
        date: Date?,
        score: Double,
        url: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.date = date
        self.score = score
        self.url = url
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            switch kind {
            case .thought:
                return "Thought"
            case .page:
                return "Page"
            case .actionItem:
                return "Todo"
            case .web:
                return "Web"
            }
        }

        return trimmedTitle
    }
}

struct ThoughtChatProposedAction: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case addThought
        case completeAction
    }

    enum Status: String, Equatable {
        case pending
        case confirmed
        case canceled
    }

    let id: UUID
    let kind: Kind
    let text: String
    let reason: String
    var targetActionID: UUID? = nil
    var status: Status
}

enum ThoughtChatUpdate {
    case partialAnswer(String)
    case finalSources([ThoughtChatSource])
    case proposedActions([ThoughtChatProposedAction])
    case responseID(String)
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
            var proposedActions: [ThoughtChatProposedAction] = []
            var responseID: String?

            do {
                for try await update in service.ask(question: question, history: history, store: store, settings: settings) {
                    guard !Task.isCancelled else {
                        return
                    }

                    switch update {
                    case .partialAnswer(let text):
                        accumulatedText = text
                        self?.updateAssistantMessage(id: assistantID, text: text, sources: finalSources, proposedActions: proposedActions)
                    case .finalSources(let sources):
                        finalSources = sources
                        self?.updateAssistantMessage(id: assistantID, text: accumulatedText, sources: sources, proposedActions: proposedActions)
                    case .proposedActions(let actions):
                        proposedActions = actions
                        self?.updateAssistantMessage(id: assistantID, text: accumulatedText, responseID: responseID, sources: finalSources, proposedActions: actions)
                    case .responseID(let id):
                        responseID = id
                        self?.updateAssistantMessage(id: assistantID, text: accumulatedText, responseID: id, sources: finalSources, proposedActions: proposedActions)
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                debugChatStream("model caught error=\(error.localizedDescription)")
                let fallbackSources = service.sources(for: question, store: store)
                let fallbackText = accumulatedText.isEmpty ? "I could not answer from your thoughts right now." : accumulatedText
                self?.updateAssistantMessage(id: assistantID, text: fallbackText, responseID: responseID, sources: fallbackSources, proposedActions: proposedActions)
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

    func confirmProposedAction(_ actionID: UUID, in messageID: UUID, store: ThoughtStore) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[messageIndex].proposedActions.firstIndex(where: { $0.id == actionID }) else {
            return
        }

        let action = messages[messageIndex].proposedActions[actionIndex]
        guard action.status == .pending else {
            return
        }

        switch action.kind {
        case .addThought:
            let thought = store.addThought(action.text)
            ThoughtProcessor.shared.enqueue(thought)
        case .completeAction:
            guard let targetActionID = action.targetActionID else {
                return
            }
            store.setActionItemDone(targetActionID, isDone: true)
        }

        messages[messageIndex].proposedActions[actionIndex].status = .confirmed
        messages.append(ThoughtChatMessage(role: .assistant, text: confirmationText(for: action)))
    }

    func cancelProposedAction(_ actionID: UUID, in messageID: UUID) {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let actionIndex = messages[messageIndex].proposedActions.firstIndex(where: { $0.id == actionID }) else {
            return
        }

        guard messages[messageIndex].proposedActions[actionIndex].status == .pending else {
            return
        }

        messages[messageIndex].proposedActions[actionIndex].status = .canceled
    }

    private func updateAssistantMessage(
        id: UUID,
        text: String,
        responseID: String? = nil,
        sources: [ThoughtChatSource],
        proposedActions: [ThoughtChatProposedAction]
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            return
        }

        debugChatStream("model update chars=\(text.count)")
        messages[index].text = text
        if let responseID {
            messages[index].responseID = responseID
        }
        messages[index].sources = sources
        messages[index].proposedActions = proposedActions
    }

    private func confirmationText(for action: ThoughtChatProposedAction) -> String {
        switch action.kind {
        case .addThought:
            return "Added that as a new thought."
        case .completeAction:
            return "Marked that todo complete."
        }
    }
}
