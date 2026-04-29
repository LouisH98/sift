import Foundation

struct ThoughtChatService {
    private let retriever = ThoughtContextRetriever()
    private let maxContextCharacters = 10_000
    private let maxAgentToolRounds = 6

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
                guard settings.canProcess else {
                    continuation.finish(throwing: ThoughtAIProviderError.unavailable("Enable AI processing in Settings to ask questions about your thoughts."))
                    return
                }

                if settings.providerKind == .openAICompatible, settings.apiEndpoint == .responses {
                    do {
                        try await askAgentically(
                            question: question,
                            history: history,
                            store: store,
                            settings: settings,
                            continuation: continuation
                        )
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                let sources = retriever.sources(for: question, store: store)
                continuation.yield(.finalSources(sources))

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

    @MainActor
    private func askAgentically(
        question: String,
        history: [ThoughtChatMessage],
        store: ThoughtStore,
        settings: AISettings,
        continuation: AsyncThrowingStream<ThoughtChatUpdate, Error>.Continuation
    ) async throws {
        var collectedSources: [ThoughtChatSource] = []
        var proposedActions: [ThoughtChatProposedAction] = []
        let client = OpenAIResponsesAgentClient(settings: settings)

        func publishSources() {
            continuation.yield(.finalSources(collectedSources))
        }

        func publishActions() {
            continuation.yield(.proposedActions(proposedActions))
        }

        let shouldSeedLocalSources = shouldSeedInitialLocalSources(for: question, history: history)
        let initialMatches = shouldSeedLocalSources ? Array(retriever.sources(for: question, store: store).prefix(8)) : []
        if !initialMatches.isEmpty {
            appendUnique(initialMatches, to: &collectedSources)
            publishSources()
        }

        let result = try await client.run(
            question: question,
            history: history,
            initialLocalSources: initialMatches,
            maxToolRounds: maxAgentToolRounds,
            runTool: { call in
                switch call.name {
                case "search_notes":
                    let arguments = SearchNotesArguments(json: call.arguments)
                    let limit = min(max(arguments.limit ?? 8, 1), 12)
                    let matches = Array(retriever.sources(for: arguments.query, store: store).prefix(limit))
                    promoteUnique(matches, in: &collectedSources)
                    publishSources()
                    return jsonString([
                        "results": matches.map(sourcePayload)
                    ])

                case "get_note_context":
                    let arguments = NoteContextArguments(json: call.arguments)
                    guard let id = UUID(uuidString: arguments.id),
                          let kind = ThoughtChatSource.Kind(rawValue: arguments.kind) else {
                        return jsonString(["error": "Expected a valid note id and kind of thought, page, or actionItem."])
                    }

                    if let source = retriever.source(id: id, kind: kind, store: store) {
                        appendUnique([source], to: &collectedSources)
                        publishSources()
                    }

                    return noteContextPayload(id: id, kind: kind, store: store)

                case "propose_add_thought":
                    let arguments = AddThoughtArguments(json: call.arguments)
                    let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else {
                        return jsonString(["error": "No thought text provided."])
                    }

                    let action = ThoughtChatProposedAction(
                        id: UUID(),
                        kind: .addThought,
                        text: text,
                        reason: arguments.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                        status: .pending
                    )
                    proposedActions.append(action)
                    publishActions()
                    return jsonString([
                        "actionId": action.id.uuidString,
                        "status": "pending_user_confirmation",
                        "message": "The user must confirm before this thought is saved."
                    ])

                default:
                    return jsonString(["error": "Unknown tool \(call.name)."])
                }
            }
        )

        appendUnique(result.webSources, to: &collectedSources)
        publishSources()
        publishActions()

        let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty {
            continuation.yield(.partialAnswer("I could not produce an answer from the available tools."))
        } else {
            continuation.yield(.partialAnswer(finalText))
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
            let sourceKind: String
            switch source.kind {
            case .thought:
                sourceKind = "thought"
            case .page:
                sourceKind = "page"
            case .actionItem:
                sourceKind = "todo"
            case .web:
                sourceKind = "web"
            }
            let date = source.date.map { DateFormatter.chatContextDate.string(from: $0) } ?? "unknown date"
            let text = """
            - \(sourceKind) id: \(source.id.uuidString)
              title: \(source.displayTitle)
              date: \(date)
              url: \(source.url?.absoluteString ?? "")
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

    private func shouldSeedInitialLocalSources(for question: String, history: [ThoughtChatMessage]) -> Bool {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let userMessages = history.filter { message in
            message.role == .user && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard userMessages.count == 1 else {
            return false
        }

        return userMessages.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuestion
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

    private func appendUnique(_ newSources: [ThoughtChatSource], to sources: inout [ThoughtChatSource]) {
        for source in newSources {
            let alreadyIncluded = sources.contains { existing in
                if let sourceURL = source.url, let existingURL = existing.url {
                    return sourceURL == existingURL
                }

                return existing.kind == source.kind && existing.id == source.id
            }

            if !alreadyIncluded {
                sources.append(source)
            }
        }
    }

    private func promoteUnique(_ promotedSources: [ThoughtChatSource], in sources: inout [ThoughtChatSource]) {
        guard !promotedSources.isEmpty else {
            return
        }

        let remainingSources = sources.filter { existing in
            !promotedSources.contains { promoted in
                if let promotedURL = promoted.url, let existingURL = existing.url {
                    return promotedURL == existingURL
                }

                return promoted.kind == existing.kind && promoted.id == existing.id
            }
        }

        sources = promotedSources + remainingSources
    }

    private func sourcePayload(_ source: ThoughtChatSource) -> [String: Any] {
        [
            "id": source.id.uuidString,
            "kind": source.kind.rawValue,
            "title": source.displayTitle,
            "snippet": source.snippet,
            "score": source.score,
            "date": source.date.map(DateFormatter.chatContextDate.string(from:)) ?? "",
            "url": source.url?.absoluteString ?? ""
        ]
    }

    @MainActor
    private func noteContextPayload(id: UUID, kind: ThoughtChatSource.Kind, store: ThoughtStore) -> String {
        switch kind {
        case .thought:
            guard let thought = store.thought(with: id) else {
                return jsonString(["error": "Thought not found."])
            }

            return jsonString([
                "id": thought.id.uuidString,
                "kind": "thought",
                "title": thought.title ?? "",
                "rawText": thought.text,
                "distilled": thought.distilled ?? "",
                "tags": thought.tags,
                "createdAt": DateFormatter.chatContextDate.string(from: thought.createdAt),
                "pageId": thought.pageID?.uuidString ?? ""
            ])

        case .page:
            guard let page = store.page(with: id) else {
                return jsonString(["error": "Page not found."])
            }

            let linkedThoughts = page.thoughtIDs
                .compactMap(store.thought(with:))
                .prefix(20)
                .map { thought in
                    [
                        "id": thought.id.uuidString,
                        "title": thought.title ?? "",
                        "rawText": truncate(thought.text, maxLength: 900),
                        "distilled": truncate(thought.distilled ?? "", maxLength: 900)
                    ]
                }

            return jsonString([
                "id": page.id.uuidString,
                "kind": "page",
                "title": page.title,
                "summary": page.summary,
                "bodyMarkdown": page.bodyMarkdown,
                "synthesisMarkdown": page.synthesisMarkdown ?? "",
                "tags": page.tags,
                "updatedAt": DateFormatter.chatContextDate.string(from: page.updatedAt),
                "linkedThoughts": Array(linkedThoughts)
            ])

        case .actionItem:
            guard let item = store.actionItems.first(where: { $0.id == id }) else {
                return jsonString(["error": "Todo not found."])
            }

            let linkedThought = store.thought(with: item.thoughtID)
            return jsonString([
                "id": item.id.uuidString,
                "kind": "actionItem",
                "title": item.title,
                "detail": item.detail ?? "",
                "status": item.isDone ? "done" : "open",
                "createdAt": DateFormatter.chatContextDate.string(from: item.createdAt),
                "completedAt": item.completedAt.map(DateFormatter.chatContextDate.string(from:)) ?? "",
                "dueDate": item.dueDate.map(DateFormatter.chatContextDate.string(from:)) ?? "",
                "dueTime": item.dueTime ?? "",
                "linkedThought": [
                    "id": linkedThought?.id.uuidString ?? "",
                    "title": linkedThought?.title ?? "",
                    "rawText": linkedThought.map { truncate($0.text, maxLength: 900) } ?? "",
                    "distilled": linkedThought.map { truncate($0.distilled ?? "", maxLength: 900) } ?? ""
                ]
            ])

        case .web:
            return jsonString(["error": "Web sources do not have local note context."])
        }
    }

    private func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"error":"Tool returned an invalid JSON payload."}"#
        }

        return string
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

private struct SearchNotesArguments {
    let query: String
    let limit: Int?

    init(json: String) {
        let object = Self.object(from: json)
        query = object["query"] as? String ?? ""
        limit = object["limit"] as? Int
    }
}

private struct NoteContextArguments {
    let id: String
    let kind: String

    init(json: String) {
        let object = Self.object(from: json)
        id = object["id"] as? String ?? ""
        kind = object["kind"] as? String ?? ""
    }
}

private struct AddThoughtArguments {
    let text: String
    let reason: String

    init(json: String) {
        let object = Self.object(from: json)
        text = object["text"] as? String ?? ""
        reason = object["reason"] as? String ?? ""
    }
}

private extension SearchNotesArguments {
    static func object(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        return object
    }
}

private extension NoteContextArguments {
    static func object(from json: String) -> [String: Any] {
        SearchNotesArguments.object(from: json)
    }
}

private extension AddThoughtArguments {
    static func object(from json: String) -> [String: Any] {
        SearchNotesArguments.object(from: json)
    }
}

private struct AgentToolCall {
    let callID: String
    let name: String
    let arguments: String
}

private struct OpenAIResponsesAgentResult {
    let text: String
    let webSources: [ThoughtChatSource]
}

@MainActor
private struct OpenAIResponsesAgentClient {
    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func run(
        question: String,
        history: [ThoughtChatMessage],
        initialLocalSources: [ThoughtChatSource],
        maxToolRounds: Int,
        runTool: @escaping (AgentToolCall) async -> String
    ) async throws -> OpenAIResponsesAgentResult {
        var input = initialInput(question: question, history: history, initialLocalSources: initialLocalSources)
        var previousResponseID: String?
        var latestText = ""
        var webSources: [ThoughtChatSource] = []

        for _ in 0...maxToolRounds {
            let response = try await createResponse(input: input, previousResponseID: previousResponseID)
            latestText = response.text
            appendUnique(response.webSources, to: &webSources)

            let calls = response.functionCalls
            guard !calls.isEmpty else {
                return OpenAIResponsesAgentResult(text: latestText, webSources: webSources)
            }

            previousResponseID = response.id
            var toolOutputs: [[String: Any]] = []
            for call in calls {
                let output = await runTool(call)
                toolOutputs.append([
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": output
                ])
            }
            input = toolOutputs
        }

        return OpenAIResponsesAgentResult(
            text: latestText.isEmpty ? "I had to stop after several tool calls. Try narrowing the request." : latestText,
            webSources: webSources
        )
    }

    private func createResponse(input: [[String: Any]], previousResponseID: String?) async throws -> OpenAIResponsesEnvelope {
        var payload: [String: Any] = [
            "model": settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "instructions": agentInstructions,
            "input": input,
            "tools": tools,
            "tool_choice": "auto",
            "parallel_tool_calls": true,
            "max_output_tokens": 2048
        ]

        if let previousResponseID {
            payload["previous_response_id"] = previousResponseID
        }

        var request = authenticatedRequest(url: try endpointURL(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAIClientError.apiError(apiErrorMessage(from: data) ?? "Agentic chat request failed with status \(httpResponse.statusCode).")
        }

        return try JSONDecoder().decode(OpenAIResponsesEnvelope.self, from: data)
    }

    private func initialInput(
        question: String,
        history: [ThoughtChatMessage],
        initialLocalSources: [ThoughtChatSource]
    ) -> [[String: Any]] {
        var priorMessages = history
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let lastMessage = priorMessages.last,
           lastMessage.role == .user,
           lastMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == question {
            priorMessages.removeLast()
        }

        let transcript = priorMessages
            .suffix(10)
            .map { message in
                let role = message.role == .user ? "User" : "Assistant"
                return "\(role): \(message.text)"
            }
            .joined(separator: "\n")

        let text = """
        Recent chat:
        \(transcript.isEmpty ? "None" : transcript)

        Initial local Sift search results:
        \(initialLocalContext(from: initialLocalSources))

        Current user request:
        \(question)
        """

        return [
            [
                "role": "user",
                "content": [
                    [
                        "type": "input_text",
                        "text": text
                    ]
                ]
            ]
        ]
    }

    private func initialLocalContext(from sources: [ThoughtChatSource]) -> String {
        guard !sources.isEmpty else {
            return "None. You should still call search_notes with a focused query before saying the notebook has no answer."
        }

        return sources.prefix(8)
            .map { source in
                """
                - kind: \(source.kind.rawValue)
                  id: \(source.id.uuidString)
                  title: \(source.displayTitle)
                  date: \(source.date.map(DateFormatter.chatContextDate.string(from:)) ?? "")
                  snippet: \(source.snippet)
                """
            }
            .joined(separator: "\n")
    }

    private var agentInstructions: String {
        """
        You are Sift's agentic chat assistant for a private thought notebook.
        Default assumption: the user is asking about their saved Sift thoughts, pages, and todos.
        Before answering any question about people, pets, dates, obligations, plans, preferences, memories, notes, or todos, call search_notes with a focused query and use those results.
        If initial local search results are present, use them and fetch full context for important results before answering.
        Do not give generic advice when local Sift results answer the question.
        Use web search only when the user explicitly asks for current, external, or public information; do not use web search for private names, pets, todos, or notebook questions.
        Never claim a new thought has been saved unless the tool result says it is pending user confirmation or the user has confirmed it.
        If the user wants to capture a new thought, call propose_add_thought with the exact thought text and a short reason.
        Be concise, preserve uncertainty, and do not expose raw tool JSON.
        """
    }

    private var tools: [[String: Any]] {
        [
            [
                "type": "web_search"
            ],
            [
                "type": "function",
                "name": "search_notes",
                "description": "Semantically search local Sift thoughts, notebook pages, and todos/action items. Read-only. Use this before answering private notebook questions.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Natural-language search query."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of note results to return.",
                            "minimum": 1,
                            "maximum": 12
                        ]
                    ],
                    "required": ["query", "limit"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "get_note_context",
                "description": "Fetch full local context for a Sift thought or notebook page by UUID. Read-only.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Thought or page UUID."
                        ],
                        "kind": [
                            "type": "string",
                            "enum": ["thought", "page", "actionItem"],
                            "description": "Whether the UUID identifies a thought, page, or todo/action item."
                        ]
                    ],
                    "required": ["id", "kind"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "propose_add_thought",
                "description": "Prepare a new thought for user confirmation. This does not save anything by itself.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "Exact thought text to save if the user confirms."
                        ],
                        "reason": [
                            "type": "string",
                            "description": "Short reason this should be saved as a thought."
                        ]
                    ],
                    "required": ["text", "reason"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let apiKey = settings.loadAPIKeyIfNeeded().trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func endpointURL(path endpointPath: String) throws -> URL {
        let rawBaseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: rawBaseURL), components.scheme != nil, components.host != nil else {
            throw OpenAIClientError.invalidBaseURL
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/\(endpointPath)" : "/\(path)/\(endpointPath)"

        guard let url = components.url else {
            throw OpenAIClientError.invalidBaseURL
        }

        return url
    }

    private func apiErrorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(OpenAIAgentErrorEnvelope.self, from: data).error.message
    }

    private func appendUnique(_ newSources: [ThoughtChatSource], to sources: inout [ThoughtChatSource]) {
        for source in newSources {
            guard !sources.contains(where: { $0.url == source.url && $0.displayTitle == source.displayTitle }) else {
                continue
            }
            sources.append(source)
        }
    }
}

private struct OpenAIResponsesEnvelope: Decodable {
    let id: String
    let output: [OpenAIResponseOutputItem]
    let outputText: String?

    enum CodingKeys: String, CodingKey {
        case id
        case output
        case outputText = "output_text"
    }

    var functionCalls: [AgentToolCall] {
        output.compactMap { item in
            guard item.type == "function_call",
                  let callID = item.callID,
                  let name = item.name else {
                return nil
            }

            return AgentToolCall(callID: callID, name: name, arguments: item.arguments ?? "{}")
        }
    }

    var webSources: [ThoughtChatSource] {
        output.flatMap(\.webSources)
    }

    var text: String {
        if let outputText, !outputText.isEmpty {
            return outputText
        }

        return output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined()
    }
}

private struct OpenAIResponseOutputItem: Decodable {
    let type: String
    let callID: String?
    let name: String?
    let arguments: String?
    let content: [OpenAIResponseContent]?

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case name
        case arguments
        case content
    }

    var webSources: [ThoughtChatSource] {
        guard type == "message" else {
            return []
        }

        return (content ?? []).flatMap(\.webSources)
    }
}

private struct OpenAIResponseContent: Decodable {
    let text: String?
    let annotations: [OpenAIResponseAnnotation]?

    var webSources: [ThoughtChatSource] {
        (annotations ?? []).compactMap { annotation in
            guard annotation.type == "url_citation",
                  let rawURL = annotation.url,
                  let url = URL(string: rawURL) else {
                return nil
            }

            return ThoughtChatSource(
                kind: .web,
                title: annotation.title ?? url.host() ?? rawURL,
                snippet: rawURL,
                date: nil,
                score: 1,
                url: url
            )
        }
    }
}

private struct OpenAIResponseAnnotation: Decodable {
    let type: String
    let url: String?
    let title: String?
}

private struct OpenAIAgentErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
