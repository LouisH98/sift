import Foundation

struct ThoughtContextRetriever {
    private let maxThoughts = 8
    private let maxPages = 5
    private let maxActionItems = 8
    private let maxSnippetLength = 220

    nonisolated init() {}

    @MainActor
    func sources(for query: String, store: ThoughtStore) -> [ThoughtChatSource] {
        var sources = lexicalSources(for: query, store: store)
        if let semanticSources = semanticSources(for: query, store: store), !semanticSources.isEmpty {
            appendUnique(semanticSources, to: &sources)
        }

        return sources.sorted(by: rankedBefore)
    }

    @MainActor
    func lexicalSources(for query: String, store: ThoughtStore) -> [ThoughtChatSource] {
        let normalizedQuery = normalize(query)
        let queryTokens = tokens(in: normalizedQuery)

        guard !queryTokens.isEmpty else {
            return []
        }

        let thoughtSources = store.thoughts
            .compactMap { thoughtSource(for: $0, query: normalizedQuery, queryTokens: queryTokens, store: store) }
            .sorted(by: rankedBefore)
            .prefix(maxThoughts)

        let pageSources = store.pages
            .compactMap { pageSource(for: $0, query: normalizedQuery, queryTokens: queryTokens) }
            .sorted(by: rankedBefore)
            .prefix(maxPages)

        let actionItemSources = store.actionItems
            .compactMap { actionItemSource(for: $0, query: normalizedQuery, queryTokens: queryTokens, store: store) }
            .sorted(by: rankedBefore)
            .prefix(maxActionItems)

        return Array(actionItemSources + thoughtSources + pageSources)
            .sorted(by: rankedBefore)
    }

    @MainActor
    func semanticSources(for query: String, store: ThoughtStore) -> [ThoughtChatSource]? {
        ThoughtEmbeddingIndex.shared.search(
            query: query,
            store: store,
            limit: maxThoughts + maxPages + maxActionItems
        )
    }

    @MainActor
    func source(id: UUID, kind: ThoughtChatSource.Kind, store: ThoughtStore) -> ThoughtChatSource? {
        switch kind {
        case .thought:
            guard let thought = store.thought(with: id) else {
                return nil
            }

            return ThoughtChatSource(
                id: thought.id,
                kind: .thought,
                title: thought.title ?? thought.text,
                snippet: bestSnippet(from: [thought.text, thought.distilled ?? "", thought.tags.joined(separator: " ")], queryTokens: []),
                date: thought.createdAt,
                score: 1
            )
        case .page:
            guard let page = store.page(with: id) else {
                return nil
            }

            return ThoughtChatSource(
                id: page.id,
                kind: .page,
                title: page.title,
                snippet: bestSnippet(from: [page.summary, page.synthesisMarkdown ?? "", page.bodyMarkdown], queryTokens: []),
                date: page.updatedAt,
                score: 1
            )
        case .actionItem:
            guard let item = store.actionItems.first(where: { $0.id == id }) else {
                return nil
            }

            return ThoughtChatSource(
                id: item.id,
                kind: .actionItem,
                title: item.title,
                snippet: actionItemSnippet(item),
                date: item.dueDate ?? item.createdAt,
                score: 1
            )
        case .web:
            return nil
        }
    }

    private func thoughtSource(
        for thought: Thought,
        query: String,
        queryTokens: Set<String>,
        store: ThoughtStore
    ) -> ThoughtChatSource? {
        let pageTitle = store.page(with: thought.pageID)?.title ?? ""
        let title = thought.title ?? thought.text
        let weightedFields: [(text: String, weight: Double)] = [
            (thought.title ?? "", 5),
            (thought.tags.joined(separator: " "), 4),
            (pageTitle, 3.5),
            (thought.text, 3),
            (thought.distilled ?? "", 2)
        ]

        let score = relevanceScore(query: query, queryTokens: queryTokens, weightedFields: weightedFields)
        guard score > 0 else {
            return nil
        }

        return ThoughtChatSource(
            id: thought.id,
            kind: .thought,
            title: title,
            snippet: bestSnippet(from: [thought.text, thought.distilled ?? "", thought.tags.joined(separator: " ")], queryTokens: queryTokens),
            date: thought.createdAt,
            score: score + recencyBoost(for: thought.createdAt)
        )
    }

    private func pageSource(for page: ThoughtPage, query: String, queryTokens: Set<String>) -> ThoughtChatSource? {
        let weightedFields: [(text: String, weight: Double)] = [
            (page.title, 5),
            (page.tags.joined(separator: " "), 4),
            (page.summary, 3.5),
            (page.synthesisMarkdown ?? "", 2.5),
            (page.bodyMarkdown, 2)
        ]

        let score = relevanceScore(query: query, queryTokens: queryTokens, weightedFields: weightedFields)
        guard score > 0 else {
            return nil
        }

        return ThoughtChatSource(
            id: page.id,
            kind: .page,
            title: page.title,
            snippet: bestSnippet(from: [page.summary, page.synthesisMarkdown ?? "", page.bodyMarkdown], queryTokens: queryTokens),
            date: page.updatedAt,
            score: score + recencyBoost(for: page.updatedAt) * 0.35
        )
    }

    private func actionItemSource(
        for item: ActionItem,
        query: String,
        queryTokens: Set<String>,
        store: ThoughtStore
    ) -> ThoughtChatSource? {
        let linkedThought = store.thought(with: item.thoughtID)
        let weightedFields: [(text: String, weight: Double)] = [
            (item.title, 6),
            (item.detail ?? "", 4),
            (actionItemDueText(item), 5),
            (linkedThought?.title ?? "", 3),
            (linkedThought?.text ?? "", 3),
            (linkedThought?.distilled ?? "", 2)
        ]

        let score = relevanceScore(query: query, queryTokens: queryTokens, weightedFields: weightedFields)
        guard score > 0 else {
            return nil
        }

        return ThoughtChatSource(
            id: item.id,
            kind: .actionItem,
            title: item.title,
            snippet: actionItemSnippet(item),
            date: item.dueDate ?? item.createdAt,
            score: score + dueBoost(for: item)
        )
    }

    private func relevanceScore(
        query: String,
        queryTokens: Set<String>,
        weightedFields: [(text: String, weight: Double)]
    ) -> Double {
        var score = 0.0

        for field in weightedFields {
            let normalizedField = normalize(field.text)
            guard !normalizedField.isEmpty else {
                continue
            }

            if normalizedField.contains(query) {
                score += field.weight * 6
            }

            let fieldTokens = tokens(in: normalizedField)
            let overlap = queryTokens.intersection(fieldTokens)
            score += Double(overlap.count) * field.weight

            for queryToken in queryTokens where queryToken.count >= 5 {
                if fieldTokens.contains(where: { $0.contains(queryToken) || queryToken.contains($0) }) {
                    score += field.weight * 0.8
                }
            }
        }

        return score
    }

    private func rankedBefore(_ lhs: ThoughtChatSource, _ rhs: ThoughtChatSource) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }

        switch (lhs.date, rhs.date) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    private func bestSnippet(from values: [String], queryTokens: Set<String>) -> String {
        let candidates = values
            .map { cleanWhitespace($0) }
            .filter { !$0.isEmpty }

        let best = candidates.max { lhs, rhs in
            snippetScore(lhs, queryTokens: queryTokens) < snippetScore(rhs, queryTokens: queryTokens)
        } ?? ""

        return truncate(best, maxLength: maxSnippetLength)
    }

    private func snippetScore(_ value: String, queryTokens: Set<String>) -> Int {
        let valueTokens = tokens(in: normalize(value))
        return queryTokens.intersection(valueTokens).count
    }

    private func recencyBoost(for date: Date) -> Double {
        let age = max(0, Date().timeIntervalSince(date))
        let days = age / 86_400
        return max(0, 2.5 - min(days, 365) / 146)
    }

    private func dueBoost(for item: ActionItem) -> Double {
        guard !item.isDone else {
            return 0.2
        }

        guard let dueDate = item.dueDate else {
            return 1.2
        }

        let age = abs(Date().timeIntervalSince(dueDate))
        let days = age / 86_400
        return max(0.5, 3 - min(days, 365) / 146)
    }

    private func actionItemSnippet(_ item: ActionItem) -> String {
        cleanWhitespace([
            item.isDone ? "Done" : "Open",
            item.title,
            item.detail ?? "",
            actionItemDueText(item)
        ].joined(separator: " "))
    }

    private func actionItemDueText(_ item: ActionItem) -> String {
        guard let dueDate = item.dueDate else {
            return "No due date"
        }

        let date = DateFormatter.chatDueDate.string(from: dueDate)
        guard let dueTime = item.dueTime, !dueTime.isEmpty else {
            return "Due \(date)"
        }

        return "Due \(date) at \(dueTime)"
    }

    private func appendUnique(_ newSources: [ThoughtChatSource], to sources: inout [ThoughtChatSource]) {
        for source in newSources where !sources.contains(where: { $0.kind == source.kind && $0.id == source.id }) {
            sources.append(source)
        }
    }

    private func normalize(_ value: String) -> String {
        cleanWhitespace(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func tokens(in value: String) -> Set<String> {
        let words = value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && !Self.stopWords.contains($0) }

        return Set(words)
    }

    private func cleanWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }

        let end = value.index(value.startIndex, offsetBy: maxLength)
        return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
        "how", "i", "in", "into", "is", "it", "me", "my", "of", "on", "or",
        "our", "that", "the", "their", "this", "to", "was", "we", "what",
        "when", "where", "which", "who", "why", "with", "you"
    ]
}

private extension DateFormatter {
    static let chatDueDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
