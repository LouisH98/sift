import Foundation

#if DEBUG
func debugChatStream(_ message: String) {
    let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
    print("[SiftChatStream \(timestamp)] \(message)")
}
#else
func debugChatStream(_ message: String) {}
#endif

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

                debugChatStream("ask start provider=\(settings.providerKind.rawValue) endpoint=\(settings.apiEndpoint.rawValue) model=\(settings.modelID)")
                if settings.providerKind == .openAICompatible, settings.apiEndpoint == .responses {
                    debugChatStream("ask branch=responses-agent")
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
                        debugChatStream("ask responses-agent failed error=\(error)")
                        continuation.finish(throwing: error)
                    }
                    return
                }

                debugChatStream("ask branch=provider-streamRawText")
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

        var streamedAnswer = ""
        let result = try await client.run(
            question: question,
            history: history,
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

                case "search_actions":
                    let arguments = SearchActionsArguments(json: call.arguments)
                    let limit = min(max(arguments.limit ?? 8, 1), 20)
                    let matches = searchActions(
                        query: arguments.query,
                        status: arguments.status,
                        due: arguments.due,
                        limit: limit,
                        store: store
                    )
                    let sources = matches.map { actionSource($0, store: store) }
                    promoteUnique(sources, in: &collectedSources)
                    publishSources()
                    return jsonString([
                        "results": matches.map { actionPayload($0, store: store) }
                    ])

                case "propose_complete_action":
                    let arguments = CompleteActionArguments(json: call.arguments)
                    guard let actionID = UUID(uuidString: arguments.actionItemID),
                          let item = store.actionItems.first(where: { $0.id == actionID }) else {
                        return jsonString(["error": "Todo not found."])
                    }

                    guard !item.isDone else {
                        return jsonString(["status": "already_done", "message": "That todo is already complete."])
                    }

                    let action = ThoughtChatProposedAction(
                        id: UUID(),
                        kind: .completeAction,
                        text: item.title,
                        reason: arguments.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                        targetActionID: item.id,
                        status: .pending
                    )
                    proposedActions.append(action)
                    publishActions()
                    return jsonString([
                        "actionId": action.id.uuidString,
                        "status": "pending_user_confirmation",
                        "message": "The user must confirm before this todo is marked complete."
                    ])

                case "get_page_tree":
                    return pageTreePayload(store: store)

                case "get_recent_activity":
                    let arguments = RecentActivityArguments(json: call.arguments)
                    let days = min(max(arguments.days ?? 7, 1), 90)
                    let limit = min(max(arguments.limit ?? 12, 1), 30)
                    return recentActivityPayload(days: days, limit: limit, store: store)

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
            },
            onTextDelta: { delta in
                debugChatStream("service delta chars=\(delta.count) before_total=\(streamedAnswer.count)")
                streamedAnswer += delta
                continuation.yield(.partialAnswer(streamedAnswer))
                debugChatStream("service yielded partial total_chars=\(streamedAnswer.count)")
            }
        )

        appendUnique(result.webSources, to: &collectedSources)
        if let responseID = result.responseID {
            continuation.yield(.responseID(responseID))
        }
        publishSources()
        publishActions()

        let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty {
            continuation.yield(.partialAnswer("I could not produce an answer from the available tools."))
        } else if streamedAnswer.trimmingCharacters(in: .whitespacesAndNewlines) != finalText {
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
    private func searchActions(
        query: String,
        status: String,
        due: String,
        limit: Int,
        store: ThoughtStore
    ) -> [ActionItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        return store.actionItems
            .filter { item in
                actionMatchesStatus(item, status: status)
                    && actionMatchesDue(item, due: due)
                    && actionMatchesQuery(item, tokens: tokens, store: store)
            }
            .sorted(by: actionSearchSort)
            .prefix(limit)
            .map { $0 }
    }

    private func actionMatchesStatus(_ item: ActionItem, status: String) -> Bool {
        switch status {
        case "open":
            return !item.isDone
        case "done":
            return item.isDone
        default:
            return true
        }
    }

    private func actionMatchesDue(_ item: ActionItem, due: String) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        switch due {
        case "overdue":
            return !item.isDone && item.isDueOverdue
        case "today":
            guard let dueDate = item.dueDate else {
                return false
            }
            return calendar.isDate(dueDate, inSameDayAs: today)
        case "upcoming":
            guard let dueAt = item.sortDueAt else {
                return false
            }
            return dueAt >= now
        case "noDue":
            return item.dueDate == nil
        default:
            return true
        }
    }

    @MainActor
    private func actionMatchesQuery(_ item: ActionItem, tokens: [String], store: ThoughtStore) -> Bool {
        guard !tokens.isEmpty else {
            return true
        }

        let thought = store.thought(with: item.thoughtID)
        let page = store.page(with: item.themeID)
        let haystack = [
            item.title,
            item.detail ?? "",
            thought?.text ?? "",
            thought?.distilled ?? "",
            page?.title ?? "",
            page?.summary ?? ""
        ]
            .joined(separator: " ")
            .lowercased()

        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func actionSearchSort(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        if lhs.isDone != rhs.isDone {
            return !lhs.isDone
        }

        switch (lhs.sortDueAt, rhs.sortDueAt) {
        case let (lhsDue?, rhsDue?) where lhsDue != rhsDue:
            return lhsDue < rhsDue
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.createdAt > rhs.createdAt
        }
    }

    @MainActor
    private func actionSource(_ item: ActionItem, store: ThoughtStore) -> ThoughtChatSource {
        ThoughtChatSource(
            id: item.id,
            kind: .actionItem,
            title: item.title,
            snippet: actionSnippet(item, store: store),
            date: item.dueDate ?? item.createdAt,
            score: item.isDone ? 0.7 : 1
        )
    }

    @MainActor
    private func actionSnippet(_ item: ActionItem, store: ThoughtStore) -> String {
        var parts: [String] = []
        if let detail = item.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(detail)
        }
        if let dueDate = item.dueDate {
            let due = [DateFormatter.chatContextDate.string(from: dueDate), item.dueTime].compactMap { $0 }.joined(separator: " ")
            parts.append("Due \(due)")
        }
        if let page = store.page(with: item.themeID) {
            parts.append("Page: \(page.title)")
        }
        return parts.isEmpty ? (item.isDone ? "Completed todo" : "Open todo") : parts.joined(separator: " · ")
    }

    @MainActor
    private func actionPayload(_ item: ActionItem, store: ThoughtStore) -> [String: Any] {
        let thought = store.thought(with: item.thoughtID)
        let page = store.page(with: item.themeID)
        return [
            "id": item.id.uuidString,
            "kind": "actionItem",
            "title": item.title,
            "detail": item.detail ?? "",
            "status": item.isDone ? "done" : "open",
            "createdAt": DateFormatter.chatContextDate.string(from: item.createdAt),
            "completedAt": item.completedAt.map(DateFormatter.chatContextDate.string(from:)) ?? "",
            "dueDate": item.dueDate.map(DateFormatter.chatContextDate.string(from:)) ?? "",
            "dueTime": item.dueTime ?? "",
            "page": [
                "id": page?.id.uuidString ?? "",
                "title": page?.title ?? ""
            ],
            "linkedThought": [
                "id": thought?.id.uuidString ?? "",
                "title": thought?.title ?? "",
                "rawText": thought.map { truncate($0.text, maxLength: 500) } ?? ""
            ]
        ]
    }

    @MainActor
    private func pageTreePayload(store: ThoughtStore) -> String {
        let childrenByParent = Dictionary(grouping: store.pages, by: \.parentID)

        func payload(for page: ThoughtPage, depth: Int) -> [String: Any] {
            let children = (childrenByParent[page.id] ?? []).sorted(by: pageTreeSort)
            return [
                "id": page.id.uuidString,
                "parentId": page.parentID?.uuidString ?? "",
                "title": page.title,
                "aliases": page.aliases,
                "summary": page.summary,
                "tags": page.tags,
                "thoughtCount": page.thoughtIDs.count,
                "updatedAt": DateFormatter.chatContextDate.string(from: page.updatedAt),
                "isStale": page.isStale,
                "depth": depth,
                "children": children.map { payload(for: $0, depth: depth + 1) }
            ]
        }

        let roots = (childrenByParent[nil] ?? []).sorted(by: pageTreeSort)
        return jsonString([
            "pages": roots.map { payload(for: $0, depth: 0) }
        ])
    }

    private func pageTreeSort(_ lhs: ThoughtPage, _ rhs: ThoughtPage) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    @MainActor
    private func recentActivityPayload(days: Int, limit: Int, store: ThoughtStore) -> String {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let recentThoughts = store.thoughts
            .filter { $0.createdAt >= since }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { thought in
                [
                    "id": thought.id.uuidString,
                    "title": thought.title ?? "",
                    "rawText": truncate(thought.text, maxLength: 500),
                    "createdAt": DateFormatter.chatContextDate.string(from: thought.createdAt),
                    "pageId": thought.pageID?.uuidString ?? ""
                ]
            }

        let updatedPages = store.pages
            .filter { $0.updatedAt >= since }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { page in
                [
                    "id": page.id.uuidString,
                    "title": page.title,
                    "aliases": page.aliases,
                    "summary": page.summary,
                    "updatedAt": DateFormatter.chatContextDate.string(from: page.updatedAt),
                    "thoughtCount": page.thoughtIDs.count
                ] as [String: Any]
            }

        let createdActions = store.actionItems
            .filter { $0.createdAt >= since }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { actionPayload($0, store: store) }

        let completedActions = store.actionItems
            .filter { item in
                guard let completedAt = item.completedAt else {
                    return false
                }
                return completedAt >= since
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(limit)
            .map { actionPayload($0, store: store) }

        return jsonString([
            "window": [
                "days": days,
                "since": DateFormatter.chatContextDate.string(from: since)
            ],
            "thoughts": Array(recentThoughts),
            "updatedPages": Array(updatedPages),
            "createdActions": Array(createdActions),
            "completedActions": Array(completedActions)
        ])
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
                "aliases": page.aliases,
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

private struct SearchActionsArguments {
    let query: String
    let status: String
    let due: String
    let limit: Int?

    init(json: String) {
        let object = Self.object(from: json)
        query = object["query"] as? String ?? ""
        status = object["status"] as? String ?? "all"
        due = object["due"] as? String ?? "all"
        limit = object["limit"] as? Int
    }
}

private struct CompleteActionArguments {
    let actionItemID: String
    let reason: String

    init(json: String) {
        let object = Self.object(from: json)
        actionItemID = object["actionItemID"] as? String ?? ""
        reason = object["reason"] as? String ?? ""
    }
}

private struct RecentActivityArguments {
    let days: Int?
    let limit: Int?

    init(json: String) {
        let object = Self.object(from: json)
        days = object["days"] as? Int
        limit = object["limit"] as? Int
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

private extension SearchActionsArguments {
    static func object(from json: String) -> [String: Any] {
        SearchNotesArguments.object(from: json)
    }
}

private extension CompleteActionArguments {
    static func object(from json: String) -> [String: Any] {
        SearchNotesArguments.object(from: json)
    }
}

private extension RecentActivityArguments {
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
    let responseID: String?
    let webSources: [ThoughtChatSource]
}

private struct OpenAIResponsesInitialInput {
    let input: [[String: Any]]
    let previousResponseID: String?
}

private enum OpenAIResponsesConversationMode {
    case stored
    case stateless
}

@MainActor
private struct OpenAIResponsesAgentClient {
    private static var statelessProviderKeys = Set<String>()

    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func run(
        question: String,
        history: [ThoughtChatMessage],
        maxToolRounds: Int,
        runTool: @escaping (AgentToolCall) async -> String,
        onTextDelta: ((String) -> Void)? = nil
    ) async throws -> OpenAIResponsesAgentResult {
        let providerKey = statelessProviderKey
        let mode: OpenAIResponsesConversationMode = Self.statelessProviderKeys.contains(providerKey) ? .stateless : .stored

        do {
            return try await run(
                question: question,
                history: history,
                mode: mode,
                maxToolRounds: maxToolRounds,
                runTool: runTool,
                onTextDelta: onTextDelta
            )
        } catch {
            guard mode == .stored, isZeroDataRetentionPreviousResponseError(error) else {
                throw error
            }

            debugChatStream("responses previous_response rejected by ZDR; retrying stateless")
            Self.statelessProviderKeys.insert(providerKey)
            return try await run(
                question: question,
                history: history,
                mode: .stateless,
                maxToolRounds: maxToolRounds,
                runTool: runTool,
                onTextDelta: onTextDelta
            )
        }
    }

    private func run(
        question: String,
        history: [ThoughtChatMessage],
        mode: OpenAIResponsesConversationMode,
        maxToolRounds: Int,
        runTool: @escaping (AgentToolCall) async -> String,
        onTextDelta: ((String) -> Void)? = nil
    ) async throws -> OpenAIResponsesAgentResult {
        let initial = initialInput(question: question, history: history, mode: mode)
        var input = initial.input
        var previousResponseID = initial.previousResponseID
        let useStoredToolContinuation = mode == .stored && previousResponseID != nil
        var latestText = ""
        var latestResponseID: String?
        var webSources: [ThoughtChatSource] = []

        debugChatStream("responses initial mode=\(mode) previous_response=\(previousResponseID != nil) input_items=\(input.count)")

        for _ in 0...maxToolRounds {
            let response = try await createResponse(
                input: input,
                previousResponseID: previousResponseID,
                mode: mode,
                onTextDelta: onTextDelta
            )
            latestText = response.text
            latestResponseID = mode == .stored && !response.id.isEmpty ? response.id : nil
            appendUnique(response.webSources, to: &webSources)
            if useStoredToolContinuation {
                previousResponseID = response.id.isEmpty ? nil : response.id
            } else {
                input.append(contentsOf: response.outputItemsForNextRequest)
                previousResponseID = nil
            }

            let calls = response.functionCalls
            guard !calls.isEmpty else {
                return OpenAIResponsesAgentResult(text: latestText, responseID: latestResponseID, webSources: webSources)
            }

            var toolOutputs: [[String: Any]] = []
            for call in calls {
                let output = await runTool(call)
                toolOutputs.append([
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": output
                ])
            }
            if useStoredToolContinuation {
                input = toolOutputs
            } else {
                input.append(contentsOf: toolOutputs)
            }
        }

        return OpenAIResponsesAgentResult(
            text: latestText.isEmpty ? "I had to stop after several tool calls. Try narrowing the request." : latestText,
            responseID: latestResponseID,
            webSources: webSources
        )
    }

    private func createResponse(
        input: [[String: Any]],
        previousResponseID: String?,
        mode: OpenAIResponsesConversationMode,
        onTextDelta: ((String) -> Void)? = nil
    ) async throws -> OpenAIResponsesEnvelope {
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

        if mode == .stateless {
            payload["store"] = false
        }

        if onTextDelta != nil {
            payload["stream"] = true
        }

        var request = authenticatedRequest(url: try endpointURL(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if onTextDelta != nil {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        if let onTextDelta {
            debugChatStream("responses stream request mode=\(mode) previous_response=\(previousResponseID != nil) input_items=\(input.count)")
            do {
                let envelope = try await streamResponse(request: request, onTextDelta: onTextDelta)
                debugChatStream("responses stream success text_chars=\(envelope.text.count) tool_calls=\(envelope.functionCalls.count)")
                return envelope
            } catch {
                debugChatStream("responses stream failed no_fallback error=\(error)")
                throw error
            }
        }

        return try await response(for: request)
    }

    private func response(for request: URLRequest) async throws -> OpenAIResponsesEnvelope {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAIClientError.apiError(apiErrorMessage(from: data) ?? "Agentic chat request failed with status \(httpResponse.statusCode).")
        }

        return try JSONDecoder().decode(OpenAIResponsesEnvelope.self, from: data)
    }

    private func streamResponse(
        request: URLRequest,
        onTextDelta: (String) -> Void
    ) async throws -> OpenAIResponsesEnvelope {
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            throw OpenAIClientError.apiError(apiErrorMessage(from: errorData) ?? "Agentic chat request failed with status \(httpResponse.statusCode).")
        }
        debugChatStream("sse http status=\(httpResponse.statusCode) content_type=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "missing")")

        var eventName: String?
        var dataLines: [String] = []
        var completedResponse: OpenAIResponsesEnvelope?
        var finalOutputText = ""
        var eventCounts: [String: Int] = [:]
        var lastEventType = "none"
        var completedDecodeError: Error?
        var completedResponseSummary = "none"

        func handleEvent() throws {
            let data = dataLines.joined(separator: "\n")
            let typeHint = eventName
            eventName = nil
            dataLines.removeAll()

            guard !data.isEmpty, data != "[DONE]" else {
                return
            }

            guard let eventObject = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
                return
            }

            let type = eventObject["type"] as? String ?? typeHint
            lastEventType = type ?? "unknown"
            eventCounts[lastEventType, default: 0] += 1

            if type == "response.output_text.delta",
               let delta = eventObject["delta"] as? String,
               !delta.isEmpty {
                debugChatStream("sse response.output_text.delta chars=\(delta.count)")
                onTextDelta(delta)
            }

            if type == "response.output_text.done",
               let text = eventObject["text"] as? String {
                finalOutputText = text
            }

            if type == "response.completed",
               let responseObject = eventObject["response"],
               let responseData = try? JSONSerialization.data(withJSONObject: responseObject) {
                completedResponseSummary = summarizeResponseObject(responseObject)
                do {
                    completedResponse = try JSONDecoder().decode(OpenAIResponsesEnvelope.self, from: responseData)
                } catch {
                    completedDecodeError = error
                    debugChatStream("sse response.completed decode_failed error=\(error)")
                    debugChatStream("sse response.completed summary=\(completedResponseSummary)")
                }
            }

            if type == "error", let errorObject = eventObject["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "AI provider returned a streaming error."
                throw OpenAIClientError.apiError(message)
            }

            if type == "response.failed",
               let responseObject = eventObject["response"] as? [String: Any],
               let errorObject = responseObject["error"] as? [String: Any] {
                let message = errorObject["message"] as? String ?? "AI provider returned a failed streaming response."
                throw OpenAIClientError.apiError(message)
            }
        }

        func handleLineData(_ lineData: Data) throws {
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" {
                line.removeLast()
            }

            if line.isEmpty {
                try handleEvent()
            } else if line.hasPrefix(":") {
                return
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        var byteCount = 0
        var lineData = Data()
        for try await byte in bytes {
            byteCount += 1
            if byte == 10 {
                try handleLineData(lineData)
                lineData.removeAll(keepingCapacity: true)
            } else {
                lineData.append(byte)
            }
        }

        if !lineData.isEmpty {
            try handleLineData(lineData)
        }

        debugChatStream("sse byte_count=\(byteCount)")

        if !dataLines.isEmpty {
            try handleEvent()
        }

        if let completedResponse {
            debugChatStream("sse completed events=\(eventCountsSummary(eventCounts)) final_text_chars=\(finalOutputText.count)")
            return completedResponse
        }

        guard !finalOutputText.isEmpty else {
            let detail = [
                "Streaming response ended without a decodable completed response.",
                "events=\(eventCountsSummary(eventCounts))",
                "last_event=\(lastEventType)",
                "final_text_chars=\(finalOutputText.count)",
                "completed_summary=\(completedResponseSummary)",
                "decode_error=\(completedDecodeError.map(String.init(describing:)) ?? "none")"
            ].joined(separator: " ")
            throw OpenAIClientError.apiError(detail)
        }

        debugChatStream("sse completed from output_text.done events=\(eventCountsSummary(eventCounts)) final_text_chars=\(finalOutputText.count)")
        return OpenAIResponsesEnvelope(outputText: finalOutputText)
    }

    private func eventCountsSummary(_ counts: [String: Int]) -> String {
        counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    private func summarizeResponseObject(_ responseObject: Any) -> String {
        guard let object = responseObject as? [String: Any] else {
            return "non_object"
        }

        let id = object["id"] as? String ?? "missing"
        let status = object["status"] as? String ?? "missing"
        let output = object["output"] as? [[String: Any]] ?? []
        let outputSummary = output.enumerated().map { index, item in
            let type = item["type"] as? String ?? "missing"
            let name = item["name"] as? String
            let content = item["content"] as? [[String: Any]] ?? []
            let contentTypes = content.compactMap { $0["type"] as? String }.joined(separator: "|")

            if let name {
                return "\(index):\(type):\(name)"
            }

            if !contentTypes.isEmpty {
                return "\(index):\(type):content=\(contentTypes)"
            }

            return "\(index):\(type)"
        }.joined(separator: ";")

        return "id=\(id) status=\(status) output_count=\(output.count) output=[\(outputSummary)]"
    }

    private func initialInput(
        question: String,
        history: [ThoughtChatMessage],
        mode: OpenAIResponsesConversationMode
    ) -> OpenAIResponsesInitialInput {
        var priorMessages = history
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if let lastMessage = priorMessages.last,
           lastMessage.role == .user,
           lastMessage.text.trimmingCharacters(in: .whitespacesAndNewlines) == question {
            priorMessages.removeLast()
        }

        if mode == .stored,
           let previousResponseID = priorMessages.reversed().compactMap(\.responseID).first {
            return OpenAIResponsesInitialInput(
                input: [messageInput(role: "user", text: question)],
                previousResponseID: previousResponseID
            )
        }

        let input = priorMessages
            .suffix(10)
            .map { message in
                messageInput(role: message.role == .user ? "user" : "assistant", text: message.text)
            } + [messageInput(role: "user", text: question)]

        return OpenAIResponsesInitialInput(input: input, previousResponseID: nil)
    }

    private func messageInput(role: String, text: String) -> [String: Any] {
        [
            "role": role,
            "content": text
        ]
    }

    private var agentInstructions: String {
        """
        You are Sift's agentic chat assistant for a private thought notebook.
        Default assumption: the user is asking about their saved Sift thoughts, pages, and todos.
        \(ThoughtChatAgentConfiguration.webSearchInstruction(isWebSearchEnabled: settings.isChatWebSearchEnabled))
        Before answering any question about people, pets, dates, obligations, plans, preferences, memories, notes, or todos, call the most relevant local tool and use those results.
        Use search_notes for general notebook questions, search_actions for todos, get_page_tree for notebook structure, and get_recent_activity for recent work.
        Do not give generic advice when local Sift results answer the question.
        Never claim a new thought has been saved unless the tool result says it is pending user confirmation or the user has confirmed it.
        If the user wants to capture a new thought, call propose_add_thought with the exact thought text and a short reason.
        If the user wants to complete a todo, call propose_complete_action. Do not mark todos complete without user confirmation.
        Be concise, preserve uncertainty, and do not expose raw tool JSON.
        """
    }

    private var tools: [[String: Any]] {
        ThoughtChatAgentConfiguration.tools(isWebSearchEnabled: settings.isChatWebSearchEnabled)
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

    private var statelessProviderKey: String {
        [
            settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "|")
    }

    private func isZeroDataRetentionPreviousResponseError(_ error: Error) -> Bool {
        guard case let OpenAIClientError.apiError(message) = error else {
            return false
        }

        let lowercased = message.lowercased()
        return lowercased.contains("previous_response_id")
            && (lowercased.contains("store")
                || lowercased.contains("zero data retention")
                || lowercased.contains("unsupported"))
    }

    private func apiErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }

        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String
        }

        return object["message"] as? String
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

enum ThoughtChatAgentConfiguration {
    static func webSearchInstruction(isWebSearchEnabled: Bool) -> String {
        if isWebSearchEnabled {
            return "Web search is available. Use it only when the user explicitly asks for current, external, or public information; do not use web search for private names, pets, todos, or notebook questions."
        }

        return "Web search is not available in this chat. Do not claim to browse the web; answer from local Sift tools or say when local context is insufficient."
    }

    static func tools(isWebSearchEnabled: Bool) -> [[String: Any]] {
        var tools: [[String: Any]] = [
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
                "description": "Fetch full local context for a Sift thought, notebook page, or todo/action item by UUID. Read-only.",
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
                "name": "search_actions",
                "description": "Search local Sift todos/action items by text, status, and due timing. Read-only.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Optional natural-language query. Use an empty string to list by status or due timing."
                        ],
                        "status": [
                            "type": "string",
                            "enum": ["all", "open", "done"],
                            "description": "Todo completion status to include."
                        ],
                        "due": [
                            "type": "string",
                            "enum": ["all", "overdue", "today", "upcoming", "noDue"],
                            "description": "Due date filter."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of todos to return.",
                            "minimum": 1,
                            "maximum": 20
                        ]
                    ],
                    "required": ["query", "status", "due", "limit"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "propose_complete_action",
                "description": "Prepare marking a todo/action item complete for user confirmation. This does not complete it by itself.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "actionItemID": [
                            "type": "string",
                            "description": "Todo/action item UUID."
                        ],
                        "reason": [
                            "type": "string",
                            "description": "Short reason this todo appears to be the one the user wants completed."
                        ]
                    ],
                    "required": ["actionItemID", "reason"],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "get_page_tree",
                "description": "Fetch the local Sift notebook page hierarchy with page IDs, summaries, tags, and thought counts. Read-only.",
                "parameters": [
                    "type": "object",
                    "properties": [:],
                    "required": [],
                    "additionalProperties": false
                ]
            ],
            [
                "type": "function",
                "name": "get_recent_activity",
                "description": "Fetch recent local Sift activity including new thoughts, updated pages, created todos, and completed todos. Read-only.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "days": [
                            "type": "integer",
                            "description": "Lookback window in days.",
                            "minimum": 1,
                            "maximum": 90
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of items per activity category.",
                            "minimum": 1,
                            "maximum": 30
                        ]
                    ],
                    "required": ["days", "limit"],
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

        if isWebSearchEnabled {
            tools.insert(["type": "web_search"], at: 0)
        }

        return tools
    }
}

private struct OpenAIResponsesEnvelope: Decodable {
    let id: String
    let output: [OpenAIResponseOutputItem]
    let outputText: String?

    init(id: String = "", output: [OpenAIResponseOutputItem] = [], outputText: String? = nil) {
        self.id = id
        self.output = output
        self.outputText = outputText
    }

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

    var outputItemsForNextRequest: [[String: Any]] {
        output.map(\.rawJSONObject)
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
    let rawValue: [String: OpenAIJSONValue]

    enum CodingKeys: String, CodingKey {
        case type
        case callID = "call_id"
        case name
        case arguments
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
        content = try container.decodeIfPresent([OpenAIResponseContent].self, forKey: .content)

        let rawContainer = try decoder.container(keyedBy: OpenAIRawCodingKey.self)
        var rawValue: [String: OpenAIJSONValue] = [:]
        for key in rawContainer.allKeys {
            rawValue[key.stringValue] = try rawContainer.decode(OpenAIJSONValue.self, forKey: key)
        }
        self.rawValue = rawValue
    }

    var webSources: [ThoughtChatSource] {
        guard type == "message" else {
            return []
        }

        return (content ?? []).flatMap(\.webSources)
    }

    var rawJSONObject: [String: Any] {
        rawValue.mapValues(\.jsonObject)
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

private struct OpenAIRawCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum OpenAIJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenAIJSONValue])
    case array([OpenAIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: OpenAIRawCodingKey.self) {
            var object: [String: OpenAIJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(OpenAIJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [OpenAIJSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(OpenAIJSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.jsonObject)
        case .array(let value):
            return value.map(\.jsonObject)
        case .null:
            return NSNull()
        }
    }
}
