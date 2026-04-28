import Foundation

struct ThoughtChatService {
    private let retriever = ThoughtContextRetriever()
    private let maxContextCharacters = 10_000

    nonisolated init() {}

    @MainActor
    func sources(for question: String, store: ThoughtStore) -> [ThoughtChatSource] {
        retriever.sources(for: question, store: store)
    }

    @MainActor
    func ask(
        question: String,
        history: [ThoughtChatMessage],
        store: ThoughtStore,
        settings: AISettings
    ) -> AsyncThrowingStream<ThoughtChatUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let sources = retriever.sources(for: question, store: store)
                continuation.yield(.finalSources(sources))

                guard settings.canProcess else {
                    continuation.finish(throwing: ThoughtAIProviderError.unavailable("Enable AI processing in Settings to ask questions about your thoughts."))
                    return
                }

                guard !sources.isEmpty else {
                    continuation.yield(.partialAnswer("I could not find enough related saved thoughts to answer that."))
                    continuation.finish()
                    return
                }

                let provider = ThoughtAIProviderFactory.provider(settings: settings, store: store)
                let prompt = answerPrompt(question: question, history: history, sources: sources)
                var accumulatedText = ""

                do {
                    for try await chunk in provider.streamRawText(
                        instructions: answerInstructions,
                        prompt: prompt
                    ) {
                        guard !Task.isCancelled else {
                            return
                        }

                        accumulatedText = chunk
                        continuation.yield(.partialAnswer(chunk))
                    }

                    if accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(.partialAnswer("I could not find enough evidence in your saved thoughts to answer that."))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private var answerInstructions: String {
        """
        You answer questions about a private Sift thought notebook.
        Use only the provided context. Do not invent facts, dates, decisions, or preferences.
        If the context is weak or missing, say that the saved thoughts do not contain enough evidence.
        Be concise and directly useful. Mention uncertainty when relevant.
        Do not include markdown source lists; the app displays sources separately.
        """
    }

    private func answerPrompt(
        question: String,
        history: [ThoughtChatMessage],
        sources: [ThoughtChatSource]
    ) -> String {
        """
        Recent chat:
        \(historyContext(from: history))

        Retrieved Sift context:
        \(sourceContext(from: sources))

        Question:
        \(question)

        Answer from the retrieved Sift context only.
        """
    }

    private func historyContext(from history: [ThoughtChatMessage]) -> String {
        let recentMessages = history.suffix(6)
        guard !recentMessages.isEmpty else {
            return "None"
        }

        return recentMessages
            .map { message in
                let role = message.role == .user ? "User" : "Assistant"
                return "\(role): \(truncate(message.text, maxLength: 700))"
            }
            .joined(separator: "\n")
    }

    private func sourceContext(from sources: [ThoughtChatSource]) -> String {
        var remainingCharacters = maxContextCharacters
        var lines: [String] = []

        for source in sources {
            let kind = source.kind == .thought ? "thought" : "page"
            let date = source.date.map { DateFormatter.chatContextDate.string(from: $0) } ?? "unknown date"
            let text = """
            - \(kind) id: \(source.id.uuidString)
              title: \(source.displayTitle)
              date: \(date)
              snippet: \(source.snippet)
            """

            guard remainingCharacters > 0 else {
                break
            }

            let clipped = truncate(text, maxLength: remainingCharacters)
            lines.append(clipped)
            remainingCharacters -= clipped.count
        }

        return lines.isEmpty ? "None" : lines.joined(separator: "\n")
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }

        guard maxLength > 3 else {
            return String(value.prefix(maxLength))
        }

        let end = value.index(value.startIndex, offsetBy: maxLength - 3)
        return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

private extension DateFormatter {
    static let chatContextDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
