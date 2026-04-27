import Combine
import Foundation

struct ThoughtProcessingInput {
    let prompt: String
}

@MainActor
final class ThoughtProcessor: ObservableObject {
    static let shared = ThoughtProcessor()

    @Published private(set) var isBackfilling = false
    @Published private(set) var lastError: String?
    @Published private var queuedThoughtIDs: Set<UUID> = []

    private let store: ThoughtStore
    private let settings: AISettings

    var isProcessing: Bool {
        isBackfilling || !queuedThoughtIDs.isEmpty
    }

    private init() {
        store = .shared
        settings = .shared
    }

    func enqueue(_ thought: Thought) {
        guard settings.canProcess else {
            return
        }

        guard !queuedThoughtIDs.contains(thought.id) else {
            return
        }

        queuedThoughtIDs.insert(thought.id)

        Task { @MainActor in
            await process(thoughtID: thought.id)
            queuedThoughtIDs.remove(thought.id)
        }
    }

    func backfillUnprocessedThoughts() {
        guard settings.canProcess, !isBackfilling else {
            return
        }

        isBackfilling = true

        Task { @MainActor in
            for thought in store.unprocessedThoughts() {
                await process(thoughtID: thought.id)
            }

            isBackfilling = false
        }
    }

    private func process(thoughtID: UUID) async {
        guard let thought = store.thought(with: thoughtID), thought.processedAt == nil else {
            return
        }

        do {
            let input = makeInput(for: thought)
            let output = try await OpenAIClient(settings: settings).process(input: input)
            apply(output, to: thought)
            lastError = nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            store.markProcessingFailed(thoughtID: thoughtID, error: message)
        }
    }

    private func makeInput(for thought: Thought) -> ThoughtProcessingInput {
        let recentThoughts = store.thoughts
            .filter { $0.id != thought.id }
            .prefix(12)
            .map { contextLine(for: $0) }
            .joined(separator: "\n")

        let themes = store.themes
            .prefix(12)
            .map { "- id: \($0.id.uuidString), title: \($0.title), summary: \($0.summary), tags: \($0.tags.joined(separator: ", "))" }
            .joined(separator: "\n")

        let existingTags = Array(Set(store.thoughts.flatMap(\.tags)))
            .sorted()
            .prefix(30)
            .joined(separator: ", ")

        let digest = store.digest(for: thought.createdAt)
        let digestContext = digest.map {
            "title: \($0.title)\nsummary: \($0.summary)\nhighlights: \($0.highlights.joined(separator: "; "))"
        } ?? "No digest for this day yet."

        let prompt = """
        New thought:
        id: \(thought.id.uuidString)
        createdAt: \(ISO8601DateFormatter().string(from: thought.createdAt))
        raw: \(thought.text)

        Recent thoughts:
        \(recentThoughts.isEmpty ? "None" : recentThoughts)

        Existing themes:
        \(themes.isEmpty ? "None" : themes)

        Existing tags:
        \(existingTags.isEmpty ? "None" : existingTags)

        Current daily digest:
        \(digestContext)

        Instructions:
        - Keep the raw thought immutable; only derive metadata.
        - Prefer an existing theme title when it fits.
        - Use linkedThoughtIds only from Recent thoughts.
        - Create actionItems only when the thought implies a concrete task, follow-up, decision, or reminder.
        - Keep action item titles short and imperative.
        """

        return ThoughtProcessingInput(prompt: prompt)
    }

    private func contextLine(for thought: Thought) -> String {
        let title = thought.title ?? thought.text
        return "- id: \(thought.id.uuidString), title: \(title), tags: \(thought.tags.joined(separator: ", "))"
    }

    private func apply(_ output: ThoughtProcessingOutput, to originalThought: Thought) {
        let now = Date()
        let linkedThoughtIDs = output.linkedThoughtIds.compactMap(UUID.init(uuidString:))
        let theme = upsertTheme(from: output, thoughtID: originalThought.id, now: now)
        let actionItems = makeActionItems(from: output, thoughtID: originalThought.id, themeID: theme.id, now: now)

        var thought = originalThought
        thought.title = clean(output.title)
        thought.distilled = clean(output.distilled)
        thought.tags = normalizedTags(output.tags)
        thought.category = theme.title
        thought.themeID = theme.id
        thought.linkedThoughtIDs = linkedThoughtIDs
        thought.processedAt = now
        thought.processingError = nil

        store.replaceThought(thought)
        store.addActionItems(actionItems)
        upsertDailyDigest(from: output, thought: thought, actionItems: actionItems, now: now)
    }

    private func upsertTheme(from output: ThoughtProcessingOutput, thoughtID: UUID, now: Date) -> Theme {
        let title = clean(output.themeTitle).isEmpty ? "Unsorted" : clean(output.themeTitle)
        let existingTheme = store.themes.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }

        var theme = existingTheme ?? Theme(
            id: UUID(),
            title: title,
            summary: "",
            tags: [],
            thoughtIDs: [],
            createdAt: now,
            updatedAt: now
        )

        theme.title = title
        theme.summary = clean(output.themeSummary)
        theme.tags = Array(Set(theme.tags + normalizedTags(output.tags))).sorted()
        if !theme.thoughtIDs.contains(thoughtID) {
            theme.thoughtIDs.append(thoughtID)
        }
        theme.updatedAt = now

        store.upsertTheme(theme)
        return theme
    }

    private func makeActionItems(
        from output: ThoughtProcessingOutput,
        thoughtID: UUID,
        themeID: UUID,
        now: Date
    ) -> [ActionItem] {
        output.actionItems.compactMap { action in
            let title = clean(action.title)
            guard !title.isEmpty else {
                return nil
            }

            let detail = clean(action.detail)
            return ActionItem(
                id: UUID(),
                thoughtID: thoughtID,
                themeID: themeID,
                title: title,
                detail: detail.isEmpty ? nil : detail,
                isDone: false,
                createdAt: now,
                completedAt: nil,
                dueAt: parseDate(action.dueAt)
            )
        }
    }

    private func upsertDailyDigest(
        from output: ThoughtProcessingOutput,
        thought: Thought,
        actionItems: [ActionItem],
        now: Date
    ) {
        let day = Calendar.current.startOfDay(for: thought.createdAt)
        var digest = store.digest(for: day) ?? DailyDigest(
            id: UUID(),
            day: day,
            title: "",
            summary: "",
            highlights: [],
            actionItemIDs: [],
            thoughtIDs: [],
            updatedAt: now
        )

        digest.title = clean(output.dailyDigestTitle)
        digest.summary = clean(output.dailyDigestSummary)
        digest.highlights = output.dailyDigestHighlights
            .map(clean)
            .filter { !$0.isEmpty }

        if !digest.thoughtIDs.contains(thought.id) {
            digest.thoughtIDs.append(thought.id)
        }

        for actionItem in actionItems where !digest.actionItemIDs.contains(actionItem.id) {
            digest.actionItemIDs.append(actionItem.id)
        }

        digest.updatedAt = now
        store.upsertDailyDigest(digest)
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { tag in
            clean(tag)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }.filter { !$0.isEmpty }))
        .sorted()
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDate(_ value: String) -> Date? {
        let trimmed = clean(value)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let date = ISO8601DateFormatter().date(from: trimmed) {
            return date
        }

        return DateFormatter.actionDate.date(from: trimmed)
    }
}

private extension DateFormatter {
    static let actionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
