import Combine
import Foundation

struct ThoughtProcessingInput {
    let prompt: String
}

struct ThoughtReorganizationInput {
    let prompt: String
}

struct ThoughtSynthesisInput {
    let prompt: String
}

@MainActor
final class ThoughtProcessor: ObservableObject {
    static let shared = ThoughtProcessor()

    @Published private(set) var isBackfilling = false
    @Published private(set) var lastError: String?
    @Published private var queuedThoughtIDs: Set<UUID> = []
    @Published private var queuedPageSynthesisIDs: Set<UUID> = []

    private let store: ThoughtStore
    private let settings: AISettings
    private let synthesisPromptVersion = "synthesis-v2-compact-markdown"

    var isProcessing: Bool {
        isBackfilling || !queuedThoughtIDs.isEmpty || !queuedPageSynthesisIDs.isEmpty
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
            let changedPageID = apply(output, to: thought)
            if let changedPageID {
                await synthesizePageAndAncestors(pageID: changedPageID)
            }
            lastError = nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            store.markProcessingFailed(thoughtID: thoughtID, error: message)
        }
    }

    func synthesizeStalePages() {
        guard settings.canProcess else {
            return
        }

        Task { @MainActor in
            let pages = store.pages
                .filter(needsSynthesis)
                .sorted { pageDepth($0) > pageDepth($1) }

            for page in pages {
                await synthesizePageAndAncestors(pageID: page.id)
            }
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

        let pages = pageContextLines()
            .joined(separator: "\n")

        let existingTags = Array(Set(store.thoughts.flatMap(\.tags)))
            .sorted()
            .prefix(30)
            .joined(separator: ", ")

        let digest = store.digest(for: thought.createdAt)
        let digestContext = digest.map {
            "title: \($0.title)\nsummary: \($0.summary)\nhighlights: \($0.highlights.joined(separator: "; "))"
        } ?? "No digest for this day yet."

        let now = Date()
        let timeZone = TimeZone.current
        let prompt = """
        New thought:
        id: \(thought.id.uuidString)
        createdAt: \(DateFormatter.promptISO8601.string(from: thought.createdAt))
        raw: \(thought.text)
        themeHint: \(thought.themeHint ?? "None")

        Current date context:
        now: \(DateFormatter.promptISO8601.string(from: now))
        timeZone: \(timeZone.identifier)
        locale: \(Locale.current.identifier)

        Recent thoughts:
        \(recentThoughts.isEmpty ? "None" : recentThoughts)

        Existing pages:
        \(pages.isEmpty ? "None" : pages)

        Existing themes:
        \(themes.isEmpty ? "None" : themes)

        Existing tags:
        \(existingTags.isEmpty ? "None" : existingTags)

        Current daily digest:
        \(digestContext)

        Instructions:
        - Keep the raw thought immutable; only derive metadata.
        - Set classification to todo, notebook, or both.
        - Prefer an existing page when it fits.
        - If themeHint is not None, strongly prefer a matching page title or create that page.
        - If no page fits and the thought belongs in the notebook, return an empty pageId and a new pageTitle.
        - Set compatibility fields themeTitle/themeSummary to match pageTitle/pageSummary.
        - Use linkedThoughtIds only from Recent thoughts.
        - Create actionItems only when the thought implies a concrete task, follow-up, decision, or reminder.
        - Keep action item titles short and imperative.
        - For each action item, set dueAt to an ISO-8601 date-time with timezone when the thought contains an explicit or strongly inferable due date/time.
        - Resolve relative due phrases like today, tomorrow, Friday, EOD, end of day, tonight, this afternoon, and next week using the current date context and local timezone.
        - Interpret EOD/end of day as 17:00 local time unless the thought gives a different time.
        - If a due date is inferable but no time is stated, choose the most useful local time for that phrase rather than midnight.
        - Leave dueAt empty when there is no due date/time signal.
        - If classification is todo and there is no reusable notebook context, leave pageId empty but still provide concise page fields.
        """

        return ThoughtProcessingInput(prompt: prompt)
    }

    private func contextLine(for thought: Thought) -> String {
        let title = thought.title ?? thought.text
        return "- id: \(thought.id.uuidString), title: \(title), tags: \(thought.tags.joined(separator: ", "))"
    }

    private func apply(_ output: ThoughtProcessingOutput, to originalThought: Thought) -> UUID? {
        let now = Date()
        let linkedThoughtIDs = output.linkedThoughtIds.compactMap(UUID.init(uuidString:))
        let page = upsertPage(from: output, thoughtID: originalThought.id, originalThought: originalThought, now: now)
        let theme = upsertTheme(from: output, thoughtID: originalThought.id, page: page, now: now)
        let actionItems = makeActionItems(from: output, thoughtID: originalThought.id, pageID: page?.id ?? theme.id, now: now)

        var thought = originalThought
        thought.title = clean(output.title)
        thought.distilled = clean(output.distilled)
        thought.tags = normalizedTags(output.tags)
        thought.category = page?.title ?? theme.title
        thought.themeID = page?.id ?? theme.id
        thought.pageID = page?.id
        thought.themeHintColorHex = originalThought.themeHint.map { ThoughtCategoryColor.hex(for: $0) } ?? page?.colorHex
        thought.linkedThoughtIDs = linkedThoughtIDs
        thought.processedAt = now
        thought.processingError = nil

        store.replaceThought(thought)
        store.addActionItems(actionItems)
        upsertDailyDigest(from: output, thought: thought, actionItems: actionItems, now: now)
        return page?.id
    }

    private func upsertPage(
        from output: ThoughtProcessingOutput,
        thoughtID: UUID,
        originalThought: Thought,
        now: Date
    ) -> ThoughtPage? {
        let classification = clean(output.classification).lowercased()
        let shouldAttachToNotebook = classification != "todo" || originalThought.themeHint != nil
        guard shouldAttachToNotebook else {
            return nil
        }

        let explicitPageID = UUID(uuidString: clean(output.pageId))
        let requestedTitle = clean(output.pageTitle).isEmpty ? clean(output.themeTitle) : clean(output.pageTitle)
        let hintedTitle = originalThought.themeHint.map(clean) ?? ""
        let title = !hintedTitle.isEmpty ? hintedTitle : (requestedTitle.isEmpty ? "Unsorted" : requestedTitle)

        let existingPage = explicitPageID.flatMap { store.page(with: $0) }
            ?? store.pages.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }

        let parentID = UUID(uuidString: clean(output.pageParentId))
        var page = existingPage ?? ThoughtPage(
            id: explicitPageID ?? UUID(),
            parentID: parentID,
            title: title,
            summary: "",
            bodyMarkdown: "",
            synthesisMarkdown: nil,
            synthesizedAt: nil,
            synthesisSourceHash: nil,
            tags: [],
            thoughtIDs: [],
            colorHex: ThoughtCategoryColor.hex(for: title),
            createdAt: now,
            updatedAt: now,
            isStale: false
        )

        page.parentID = page.id == parentID ? page.parentID : parentID
        page.title = title
        page.summary = clean(output.pageSummary).isEmpty ? clean(output.themeSummary) : clean(output.pageSummary)
        page.bodyMarkdown = clean(output.pageBodyMarkdown).isEmpty ? clean(output.distilled) : clean(output.pageBodyMarkdown)
        page.tags = Array(Set(page.tags + normalizedTags(output.tags))).sorted()
        page.colorHex = page.colorHex ?? ThoughtCategoryColor.hex(for: title)
        if !page.thoughtIDs.contains(thoughtID) {
            page.thoughtIDs.append(thoughtID)
        }
        page.updatedAt = now
        page.isStale = false

        store.upsertPage(page)
        return page
    }

    private func upsertTheme(from output: ThoughtProcessingOutput, thoughtID: UUID, page: ThoughtPage?, now: Date) -> Theme {
        let title = page?.title ?? (clean(output.themeTitle).isEmpty ? "Unsorted" : clean(output.themeTitle))
        let existingTheme = store.themes.first { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }

        var theme = existingTheme ?? Theme(
            id: page?.id ?? UUID(),
            title: title,
            summary: "",
            tags: [],
            thoughtIDs: [],
            createdAt: now,
            updatedAt: now
        )

        theme.title = title
        theme.summary = page?.summary ?? clean(output.themeSummary)
        theme.tags = Array(Set(theme.tags + normalizedTags(output.tags))).sorted()
        if page != nil, !theme.thoughtIDs.contains(thoughtID) {
            theme.thoughtIDs.append(thoughtID)
        }
        theme.updatedAt = now

        store.upsertTheme(theme)
        return theme
    }

    private func makeActionItems(
        from output: ThoughtProcessingOutput,
        thoughtID: UUID,
        pageID: UUID,
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
                themeID: pageID,
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

    private func synthesizePageAndAncestors(pageID: UUID) async {
        var ids: [UUID] = []
        var currentID: UUID? = pageID

        while let id = currentID {
            ids.append(id)
            currentID = store.page(with: id)?.parentID
        }

        for id in ids {
            await synthesize(pageID: id)
        }
    }

    private func synthesize(pageID: UUID) async {
        guard settings.canProcess, !queuedPageSynthesisIDs.contains(pageID), let page = store.page(with: pageID) else {
            return
        }

        let source = synthesisSource(for: page)
        let sourceHash = stableHash("\(synthesisPromptVersion)\n\(source)")
        guard page.synthesisSourceHash != sourceHash || page.isStale || clean(page.synthesisMarkdown ?? "").isEmpty else {
            return
        }

        queuedPageSynthesisIDs.insert(pageID)
        defer {
            queuedPageSynthesisIDs.remove(pageID)
        }

        do {
            let prompt = """
            Page to synthesize:
            \(source)

            Instructions:
            - Write this as the default page view, not as metadata.
            - Do not merely restate the raw notes; integrate them into a coherent read.
            - Keep it concise: 80-140 words unless the page genuinely needs more.
            - Use valid markdown with blank lines between blocks.
            - Prefer 2-4 short sections using level-2 headings, such as "## What this means", "## Patterns", or "## Open loops".
            - Use bullets for scan-friendly points. Avoid dense paragraphs.
            - Call out patterns, tensions, open loops, decisions implied, and emerging subtopics only when present.
            - Preserve uncertainty. Do not invent facts beyond the provided notes.
            """

            let output = try await OpenAIClient(settings: settings).synthesizePage(input: ThoughtSynthesisInput(prompt: prompt))
            store.updatePageSynthesis(
                pageID: pageID,
                synthesisMarkdown: clean(output.synthesisMarkdown),
                sourceHash: sourceHash
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func needsSynthesis(_ page: ThoughtPage) -> Bool {
        let sourceHash = stableHash("\(synthesisPromptVersion)\n\(synthesisSource(for: page))")
        return page.isStale || page.synthesisSourceHash != sourceHash || clean(page.synthesisMarkdown ?? "").isEmpty
    }

    private func synthesisSource(for page: ThoughtPage) -> String {
        let linkedThoughts = page.thoughtIDs
            .compactMap(store.thought(with:))
            .sorted { $0.createdAt < $1.createdAt }
            .map { thought in
                """
                - id: \(thought.id.uuidString)
                  createdAt: \(ISO8601DateFormatter().string(from: thought.createdAt))
                  title: \(thought.title ?? "")
                  raw: \(thought.text)
                  distilled: \(thought.distilled ?? "")
                  tags: \(thought.tags.joined(separator: ", "))
                """
            }
            .joined(separator: "\n")

        let childPages = store.pages
            .filter { $0.parentID == page.id }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { child in
                """
                - id: \(child.id.uuidString)
                  title: \(child.title)
                  summary: \(child.summary)
                  synthesis: \(child.synthesisMarkdown ?? "")
                """
            }
            .joined(separator: "\n")

        return """
        id: \(page.id.uuidString)
        title: \(page.title)
        summary: \(page.summary)
        distilledBody:
        \(page.bodyMarkdown)

        childPages:
        \(childPages.isEmpty ? "None" : childPages)

        linkedRawThoughts:
        \(linkedThoughts.isEmpty ? "None" : linkedThoughts)
        """
    }

    private func stableHash(_ value: String) -> String {
        let hash = value.unicodeScalars.reduce(UInt64(14695981039346656037)) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1099511628211
        }

        return String(hash, radix: 16)
    }

    private func pageDepth(_ page: ThoughtPage) -> Int {
        var depth = 0
        var parentID = page.parentID

        while let id = parentID, let parent = store.page(with: id) {
            depth += 1
            parentID = parent.parentID
        }

        return depth
    }

    private func pageContextLines() -> [String] {
        let childrenByParentID = Dictionary(grouping: store.pages, by: \.parentID)
        let rootPages = (childrenByParentID[nil] ?? [])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return rootPages.flatMap { pageLines(for: $0, childrenByParentID: childrenByParentID, depth: 0) }
    }

    private func pageLines(
        for page: ThoughtPage,
        childrenByParentID: [UUID?: [ThoughtPage]],
        depth: Int
    ) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines = [
            "\(indent)- id: \(page.id.uuidString), parentId: \(page.parentID?.uuidString ?? "none"), title: \(page.title), summary: \(page.summary), tags: \(page.tags.joined(separator: ", "))"
        ]

        let children = (childrenByParentID[page.id] ?? [])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        for child in children {
            lines.append(contentsOf: pageLines(for: child, childrenByParentID: childrenByParentID, depth: depth + 1))
        }

        return lines
    }
}

private extension DateFormatter {
    static let promptISO8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static let actionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
