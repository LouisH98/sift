import Combine
import Foundation

@MainActor
final class ThoughtReorganizer: ObservableObject {
    @Published private(set) var isReorganizing = false
    @Published private(set) var lastError: String?

    private let store: ThoughtStore
    private let settings: AISettings

    init() {
        self.store = .shared
        self.settings = .shared
    }

    init(store: ThoughtStore, settings: AISettings) {
        self.store = store
        self.settings = settings
    }

    func makeProposal() async -> ReorganizationProposal? {
        guard settings.canProcess else {
            lastError = "Enable AI processing in Settings to tidy the notebook."
            return nil
        }

        guard !store.thoughts.isEmpty else {
            lastError = "Capture some thoughts before tidying the notebook."
            return nil
        }

        isReorganizing = true
        defer {
            isReorganizing = false
        }

        do {
            let input = ThoughtReorganizationInput(prompt: makePrompt())
            let proposal = try await OpenAIClient(settings: settings).reorganize(input: input)
            lastError = nil
            return proposal
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func makePrompt() -> String {
        let thoughts = store.thoughts
            .sorted { $0.createdAt < $1.createdAt }
            .map { thought in
                """
                - id: \(thought.id.uuidString)
                  createdAt: \(ISO8601DateFormatter().string(from: thought.createdAt))
                  title: \(thought.title ?? "")
                  raw: \(thought.text)
                  distilled: \(thought.distilled ?? "")
                  currentPageId: \(thought.pageID?.uuidString ?? "")
                  tags: \(thought.tags.joined(separator: ", "))
                """
            }
            .joined(separator: "\n")

        let pages = pageContextLines().joined(separator: "\n")

        return """
        Raw thoughts:
        \(thoughts)

        Current pages:
        \(pages.isEmpty ? "None" : pages)

        Instructions:
        - Return a complete proposed page tree, not just the changed pages.
        - Every thought ID must appear in at least one proposed page.
        - Use existingPageId when retaining, renaming, moving, or rewriting an existing page.
        - Use a stable new id such as new-product-strategy for new pages.
        - Use parentId to reference another proposed page id or existing page UUID; use an empty string for top-level pages.
        - Put obsolete existing page UUIDs in deletedPageIds.
        - Keep summaries concise and bodyMarkdown useful as a Notion-like page body.
        """
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
            "\(indent)- id: \(page.id.uuidString), parentId: \(page.parentID?.uuidString ?? "none"), title: \(page.title), summary: \(page.summary), thoughts: \(page.thoughtIDs.count)"
        ]

        let children = (childrenByParentID[page.id] ?? [])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        for child in children {
            lines.append(contentsOf: pageLines(for: child, childrenByParentID: childrenByParentID, depth: depth + 1))
        }

        return lines
    }
}
