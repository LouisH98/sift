import Combine
import Foundation

@MainActor
final class ThoughtStore: ObservableObject {
    static let shared = ThoughtStore()

    @Published private(set) var thoughts: [Thought] = []
    @Published private(set) var themes: [Theme] = []
    @Published private(set) var pages: [ThoughtPage] = []
    @Published private(set) var dailyDigests: [DailyDigest] = []
    @Published private(set) var actionItems: [ActionItem] = []

    private let thoughtsURL: URL
    private let themesURL: URL
    private let pagesURL: URL
    private let dailyDigestsURL: URL
    private let actionItemsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = supportURL.appendingPathComponent("ThoughtNotch", isDirectory: true)
        thoughtsURL = directoryURL.appendingPathComponent("thoughts.json")
        themesURL = directoryURL.appendingPathComponent("themes.json")
        pagesURL = directoryURL.appendingPathComponent("pages.json")
        dailyDigestsURL = directoryURL.appendingPathComponent("daily-digests.json")
        actionItemsURL = directoryURL.appendingPathComponent("action-items.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    var openActionItems: [ActionItem] {
        actionItems
            .filter { !$0.isDone }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var unprocessedThoughtCount: Int {
        thoughts.filter { $0.processedAt == nil }.count
    }

    func addThought(_ text: String) -> Thought {
        let hint = ThoughtPrefixParser.themeHint(in: text)
        let thought = Thought(
            text: text,
            createdAt: Date(),
            themeHint: hint?.title,
            themeHintPrefixLength: hint?.prefixLength,
            themeHintColorHex: hint.map { ThoughtCategoryColor.hex(for: $0.title) }
        )

        thoughts.insert(thought, at: 0)
        saveThoughts()
        return thought
    }

    func thought(with id: UUID) -> Thought? {
        thoughts.first { $0.id == id }
    }

    func theme(with id: UUID?) -> Theme? {
        guard let id else {
            return nil
        }

        return themes.first { $0.id == id }
    }

    func page(with id: UUID?) -> ThoughtPage? {
        guard let id else {
            return nil
        }

        return pages.first { $0.id == id }
    }

    func replaceThought(_ thought: Thought) {
        guard let index = thoughts.firstIndex(where: { $0.id == thought.id }) else {
            return
        }

        thoughts[index] = thought
        thoughts.sort { $0.createdAt > $1.createdAt }
        saveThoughts()
    }

    func markProcessingFailed(thoughtID: UUID, error: String) {
        guard var thought = thought(with: thoughtID) else {
            return
        }

        thought.processingError = error
        replaceThought(thought)
    }

    func upsertTheme(_ theme: Theme) {
        if let index = themes.firstIndex(where: { $0.id == theme.id }) {
            themes[index] = theme
        } else {
            themes.insert(theme, at: 0)
        }

        themes.sort { $0.updatedAt > $1.updatedAt }
        saveThemes()
    }

    func upsertPage(_ page: ThoughtPage) {
        var page = page
        page.colorHex = page.colorHex ?? ThoughtCategoryColor.hex(for: page.title)

        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            pages[index] = page
        } else {
            pages.insert(page, at: 0)
        }

        pages.sort(by: pageSort)
        savePages()
    }

    func movePage(_ id: UUID, to parentID: UUID?) {
        guard let index = pages.firstIndex(where: { $0.id == id }), id != parentID else {
            return
        }

        if let parentID, wouldCreateCycle(pageID: id, parentID: parentID) {
            return
        }

        pages[index].parentID = parentID
        pages[index].updatedAt = Date()
        pages.sort(by: pageSort)
        savePages()
    }

    func renamePage(_ id: UUID, title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, let index = pages.firstIndex(where: { $0.id == id }) else {
            return
        }

        pages[index].title = cleanTitle
        pages[index].updatedAt = Date()
        savePages()
    }

    func deletePage(_ id: UUID) {
        guard let deletedPage = page(with: id) else {
            return
        }

        let now = Date()
        var unsorted = unsortedPage(now: now)
        let descendantIDs = descendantPageIDs(of: id)
        let removedIDs = descendantIDs.union([id])
        let orphanedThoughtIDs = pages
            .filter { removedIDs.contains($0.id) }
            .flatMap(\.thoughtIDs)

        pages.removeAll { removedIDs.contains($0.id) }
        for thoughtID in orphanedThoughtIDs where !unsorted.thoughtIDs.contains(thoughtID) {
            unsorted.thoughtIDs.append(thoughtID)
        }

        unsorted.updatedAt = now
        unsorted.isStale = true
        upsertPageWithoutSaving(unsorted)

        for index in thoughts.indices where orphanedThoughtIDs.contains(thoughts[index].id) {
            thoughts[index].pageID = unsorted.id
            thoughts[index].themeID = unsorted.id
            thoughts[index].category = unsorted.title
        }

        for index in actionItems.indices where orphanedThoughtIDs.contains(actionItems[index].thoughtID) {
            actionItems[index].themeID = unsorted.id
        }

        pages.sort(by: pageSort)
        saveThoughts()
        saveActionItems()
        savePages()

        NSLog("ThoughtNotch moved thoughts from deleted page \(deletedPage.title) to Unsorted.")
    }

    func deleteThought(_ id: UUID) {
        guard let deletedThought = thought(with: id) else {
            return
        }

        thoughts.removeAll { $0.id == id }
        actionItems.removeAll { $0.thoughtID == id }

        var touchedPageIDs = Set<UUID>()
        for index in pages.indices where pages[index].thoughtIDs.contains(id) {
            pages[index].thoughtIDs.removeAll { $0 == id }
            pages[index].isStale = true
            pages[index].updatedAt = Date()
            touchedPageIDs.insert(pages[index].id)
        }

        for index in dailyDigests.indices {
            dailyDigests[index].thoughtIDs.removeAll { $0 == id }
            dailyDigests[index].actionItemIDs.removeAll { actionID in
                !actionItems.contains(where: { $0.id == actionID })
            }
            if Calendar.current.isDate(dailyDigests[index].day, inSameDayAs: deletedThought.createdAt) {
                dailyDigests[index].updatedAt = Date()
            }
        }

        if let pageID = deletedThought.pageID, !touchedPageIDs.contains(pageID), let index = pages.firstIndex(where: { $0.id == pageID }) {
            pages[index].isStale = true
            pages[index].updatedAt = Date()
        }

        saveThoughts()
        saveActionItems()
        saveDailyDigests()
        savePages()
    }

    func applyReorganizationProposal(_ proposal: ReorganizationProposal) {
        let now = Date()
        let oldPagesByID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var proposedIDMap: [String: UUID] = [:]

        for proposedPage in proposal.pages {
            if let existingPageID = proposedPage.existingPageID, oldPagesByID[existingPageID] != nil {
                proposedIDMap[proposedPage.id] = existingPageID
            } else if let parsedID = UUID(uuidString: proposedPage.id), oldPagesByID[parsedID] != nil {
                proposedIDMap[proposedPage.id] = parsedID
            } else {
                proposedIDMap[proposedPage.id] = UUID()
            }
        }

        let deletedPageIDs = Set(proposal.deletedPageIDs)
        let allAssignedThoughtIDs = Set(proposal.pages.flatMap(\.thoughtIDs))
        var nextPages: [ThoughtPage] = proposal.pages.compactMap { proposedPage in
            guard let resolvedID = proposedIDMap[proposedPage.id] else {
                return nil
            }

            let oldPage = oldPagesByID[resolvedID]
            let parentResolvedID = proposedPage.parentID.flatMap { proposedIDMap[$0] ?? UUID(uuidString: $0) }
            let title = proposedPage.title.trimmingCharacters(in: .whitespacesAndNewlines)

            return ThoughtPage(
                id: resolvedID,
                parentID: parentResolvedID == resolvedID ? nil : parentResolvedID,
                title: title.isEmpty ? "Untitled" : title,
                summary: proposedPage.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                bodyMarkdown: proposedPage.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines),
                tags: normalizedTags(proposedPage.tags),
                thoughtIDs: validThoughtIDs(proposedPage.thoughtIDs),
                colorHex: oldPage?.colorHex ?? ThoughtCategoryColor.hex(for: title),
                createdAt: oldPage?.createdAt ?? now,
                updatedAt: now,
                isStale: false
            )
        }

        let droppedThoughtIDs = thoughts
            .map(\.id)
            .filter { !allAssignedThoughtIDs.contains($0) }

        if !droppedThoughtIDs.isEmpty {
            var unsorted = nextPages.first { $0.title.localizedCaseInsensitiveCompare("Unsorted") == .orderedSame }
                ?? unsortedPage(now: now)

            for thoughtID in droppedThoughtIDs where !unsorted.thoughtIDs.contains(thoughtID) {
                unsorted.thoughtIDs.append(thoughtID)
            }

            unsorted.updatedAt = now
            unsorted.isStale = true

            nextPages.removeAll { $0.id == unsorted.id }
            nextPages.append(unsorted)
        }

        let retainedPageIDs = Set(nextPages.map(\.id))
        let orphanedFromDeletedPages = pages
            .filter { deletedPageIDs.contains($0.id) && !retainedPageIDs.contains($0.id) }
            .flatMap(\.thoughtIDs)

        if !orphanedFromDeletedPages.isEmpty {
            var unsorted = nextPages.first { $0.title.localizedCaseInsensitiveCompare("Unsorted") == .orderedSame }
                ?? unsortedPage(now: now)

            for thoughtID in orphanedFromDeletedPages where !unsorted.thoughtIDs.contains(thoughtID) {
                unsorted.thoughtIDs.append(thoughtID)
            }

            unsorted.updatedAt = now
            unsorted.isStale = true
            nextPages.removeAll { $0.id == unsorted.id }
            nextPages.append(unsorted)
        }

        pages = nextPages.sorted(by: pageSort)
        syncThoughtPageReferences()
        savePages()
        saveThoughts()
    }

    func upsertDailyDigest(_ digest: DailyDigest) {
        if let index = dailyDigests.firstIndex(where: { Calendar.current.isDate($0.day, inSameDayAs: digest.day) }) {
            dailyDigests[index] = digest
        } else {
            dailyDigests.insert(digest, at: 0)
        }

        dailyDigests.sort { $0.day > $1.day }
        saveDailyDigests()
    }

    func addActionItems(_ items: [ActionItem]) {
        guard !items.isEmpty else {
            return
        }

        for item in items where !actionItems.contains(where: { $0.id == item.id }) {
            actionItems.insert(item, at: 0)
        }

        actionItems.sort { $0.createdAt > $1.createdAt }
        saveActionItems()
    }

    func setActionItemDone(_ id: UUID, isDone: Bool) {
        guard let index = actionItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        actionItems[index].isDone = isDone
        actionItems[index].completedAt = isDone ? Date() : nil
        saveActionItems()
    }

    func digest(for day: Date) -> DailyDigest? {
        dailyDigests.first { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    func unprocessedThoughts() -> [Thought] {
        thoughts
            .filter { $0.processedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func load() {
        thoughts = loadArray(from: thoughtsURL, fallback: [])
            .sorted { $0.createdAt > $1.createdAt }
        themes = loadArray(from: themesURL, fallback: [])
            .sorted { $0.updatedAt > $1.updatedAt }
        pages = loadArray(from: pagesURL, fallback: [])
            .sorted(by: pageSort)
        dailyDigests = loadArray(from: dailyDigestsURL, fallback: [])
            .sorted { $0.day > $1.day }
        actionItems = loadArray(from: actionItemsURL, fallback: [])
            .sorted { $0.createdAt > $1.createdAt }

        migrateThemesToPagesIfNeeded()
        backfillThoughtPrefixHintsIfNeeded()
        backfillPageColorsIfNeeded()
        syncThoughtPageReferences()
    }

    private func loadArray<T: Decodable>(from url: URL, fallback: [T]) -> [T] {
        do {
            try FileManager.default.createDirectory(
                at: thoughtsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard FileManager.default.fileExists(atPath: url.path) else {
                return fallback
            }

            let data = try Data(contentsOf: url)
            return try decoder.decode([T].self, from: data)
        } catch {
            NSLog("ThoughtNotch failed to load \(url.lastPathComponent): \(error.localizedDescription)")
            return fallback
        }
    }

    private func saveThoughts() {
        save(thoughts, to: thoughtsURL)
    }

    private func saveThemes() {
        save(themes, to: themesURL)
    }

    private func savePages() {
        save(pages, to: pagesURL)
    }

    private func saveDailyDigests() {
        save(dailyDigests, to: dailyDigestsURL)
    }

    private func saveActionItems() {
        save(actionItems, to: actionItemsURL)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("ThoughtNotch failed to save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func migrateThemesToPagesIfNeeded() {
        guard pages.isEmpty, !themes.isEmpty else {
            return
        }

        pages = themes.map { theme in
            ThoughtPage(
                id: theme.id,
                parentID: nil,
                title: theme.title,
                summary: theme.summary,
                bodyMarkdown: theme.summary,
                tags: theme.tags,
                thoughtIDs: theme.thoughtIDs,
                colorHex: ThoughtCategoryColor.hex(for: theme.title),
                createdAt: theme.createdAt,
                updatedAt: theme.updatedAt,
                isStale: false
            )
        }
        .sorted(by: pageSort)

        for index in thoughts.indices where thoughts[index].pageID == nil {
            guard let themeID = thoughts[index].themeID else {
                continue
            }

            thoughts[index].pageID = themeID
        }

        savePages()
        saveThoughts()
    }

    private func backfillThoughtPrefixHintsIfNeeded() {
        var changed = false

        for index in thoughts.indices {
            guard let hint = ThoughtPrefixParser.themeHint(in: thoughts[index].text) else {
                continue
            }

            let colorHex = ThoughtCategoryColor.hex(for: hint.title)
            if thoughts[index].themeHint != hint.title
                || thoughts[index].themeHintPrefixLength != hint.prefixLength
                || thoughts[index].themeHintColorHex != colorHex {
                thoughts[index].themeHint = hint.title
                thoughts[index].themeHintPrefixLength = hint.prefixLength
                thoughts[index].themeHintColorHex = colorHex
                changed = true
            }
        }

        if changed {
            saveThoughts()
        }
    }

    private func backfillPageColorsIfNeeded() {
        var changed = false

        for index in pages.indices where pages[index].colorHex == nil {
            pages[index].colorHex = ThoughtCategoryColor.hex(for: pages[index].title)
            changed = true
        }

        if changed {
            savePages()
        }
    }

    private func syncThoughtPageReferences() {
        var thoughtToPageID: [UUID: ThoughtPage] = [:]

        for page in pages {
            for thoughtID in page.thoughtIDs {
                thoughtToPageID[thoughtID] = page
            }
        }

        var changedThoughts = false
        for index in thoughts.indices {
            guard let page = thoughtToPageID[thoughts[index].id] else {
                continue
            }

            if thoughts[index].pageID != page.id || thoughts[index].themeID != page.id || thoughts[index].category != page.title {
                thoughts[index].pageID = page.id
                thoughts[index].themeID = page.id
                thoughts[index].category = page.title
                changedThoughts = true
            }
        }

        if changedThoughts {
            saveThoughts()
        }
    }

    private func unsortedPage(now: Date) -> ThoughtPage {
        if let existing = pages.first(where: { $0.title.localizedCaseInsensitiveCompare("Unsorted") == .orderedSame }) {
            return existing
        }

        return ThoughtPage(
            id: UUID(),
            parentID: nil,
            title: "Unsorted",
            summary: "Thoughts waiting for a better home.",
            bodyMarkdown: "Thoughts waiting for a better home.",
            tags: [],
            thoughtIDs: [],
            colorHex: ThoughtCategoryColor.hex(for: "Unsorted"),
            createdAt: now,
            updatedAt: now,
            isStale: true
        )
    }

    private func upsertPageWithoutSaving(_ page: ThoughtPage) {
        if let index = pages.firstIndex(where: { $0.id == page.id }) {
            pages[index] = page
        } else {
            pages.append(page)
        }
    }

    private func descendantPageIDs(of id: UUID) -> Set<UUID> {
        var descendants = Set<UUID>()
        var frontier = [id]

        while let parentID = frontier.popLast() {
            let children = pages.filter { $0.parentID == parentID }.map(\.id)
            for childID in children where !descendants.contains(childID) {
                descendants.insert(childID)
                frontier.append(childID)
            }
        }

        return descendants
    }

    private func wouldCreateCycle(pageID: UUID, parentID: UUID) -> Bool {
        var currentParentID: UUID? = parentID

        while let id = currentParentID {
            if id == pageID {
                return true
            }

            currentParentID = pages.first { $0.id == id }?.parentID
        }

        return false
    }

    private func validThoughtIDs(_ ids: [UUID]) -> [UUID] {
        let existingIDs = Set(thoughts.map(\.id))
        var seen = Set<UUID>()

        return ids.filter { id in
            guard existingIDs.contains(id), !seen.contains(id) else {
                return false
            }

            seen.insert(id)
            return true
        }
    }

    private func normalizedTags(_ tags: [String]) -> [String] {
        Array(Set(tags.map { tag in
            tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }.filter { !$0.isEmpty }))
        .sorted()
    }

    private func pageSort(_ lhs: ThoughtPage, _ rhs: ThoughtPage) -> Bool {
        if lhs.parentID == nil, rhs.parentID != nil {
            return true
        }

        if lhs.parentID != nil, rhs.parentID == nil {
            return false
        }

        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
