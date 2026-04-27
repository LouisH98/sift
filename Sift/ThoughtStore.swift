import Combine
import Foundation
import UserNotifications

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
        let directoryURL = AppIdentity.applicationSupportDirectory()
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
            .sorted(by: actionItemSort)
    }

    var recentlyCompletedActionItems: [ActionItem] {
        actionItems
            .filter { item in
                guard item.isDone, let completedAt = item.completedAt else {
                    return false
                }

                return Calendar.current.isDateInToday(completedAt)
            }
            .sorted { lhs, rhs in
                switch (lhs.completedAt, rhs.completedAt) {
                case let (lhsCompletedAt?, rhsCompletedAt?) where lhsCompletedAt != rhsCompletedAt:
                    return lhsCompletedAt > rhsCompletedAt
                default:
                    return actionItemSort(lhs, rhs)
                }
            }
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
            let existingPage = pages[index]
            if page.synthesisMarkdown == nil {
                page.synthesisMarkdown = existingPage.synthesisMarkdown
                page.synthesizedAt = existingPage.synthesizedAt
                page.synthesisSourceHash = existingPage.synthesisSourceHash
            }

            if existingPage.title != page.title
                || existingPage.summary != page.summary
                || existingPage.bodyMarkdown != page.bodyMarkdown
                || existingPage.parentID != page.parentID
                || existingPage.thoughtIDs != page.thoughtIDs {
                page.isStale = true
            }

            pages[index] = page
        } else {
            page.isStale = true
            pages.insert(page, at: 0)
        }

        pages.sort(by: pageSort)
        savePages()
    }

    func updatePageSynthesis(pageID: UUID, synthesisMarkdown: String, sourceHash: String, synthesizedAt: Date = Date()) {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            return
        }

        pages[index].synthesisMarkdown = synthesisMarkdown
        pages[index].synthesizedAt = synthesizedAt
        pages[index].synthesisSourceHash = sourceHash
        pages[index].isStale = false
        pages[index].updatedAt = synthesizedAt
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
        pages[index].isStale = true
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
        pages[index].isStale = true
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

            NSLog("Sift moved thoughts from deleted page \(deletedPage.title) to Unsorted.")
    }

    func deleteThought(_ id: UUID) {
        guard let deletedThought = thought(with: id) else {
            return
        }

        let removedActionItemIDs = actionItems
            .filter { $0.thoughtID == id }
            .map(\.id)

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
        ActionReminderScheduler.shared.cancel(actionItemIDs: removedActionItemIDs)
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
                synthesisMarkdown: oldPage?.synthesisMarkdown,
                synthesizedAt: oldPage?.synthesizedAt,
                synthesisSourceHash: oldPage?.synthesisSourceHash,
                tags: normalizedTags(proposedPage.tags),
                thoughtIDs: validThoughtIDs(proposedPage.thoughtIDs),
                colorHex: oldPage?.colorHex ?? ThoughtCategoryColor.hex(for: title),
                createdAt: oldPage?.createdAt ?? now,
                updatedAt: now,
                isStale: true
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

        actionItems.sort(by: actionItemSort)
        saveActionItems()
        ActionReminderScheduler.shared.sync(actionItems: items, settings: TodoSettings.shared)
    }

    func setActionItemDone(_ id: UUID, isDone: Bool) {
        guard let index = actionItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        actionItems[index].isDone = isDone
        actionItems[index].completedAt = isDone ? Date() : nil
        saveActionItems()

        if isDone {
            ActionReminderScheduler.shared.cancel(actionItemIDs: [id])
        } else {
            ActionReminderScheduler.shared.sync(actionItems: [actionItems[index]], settings: TodoSettings.shared)
        }
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
            .sorted(by: actionItemSort)

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
            NSLog("Sift failed to load \(url.lastPathComponent): \(error.localizedDescription)")
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
            NSLog("Sift failed to save \(url.lastPathComponent): \(error.localizedDescription)")
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
                synthesisMarkdown: nil,
                synthesizedAt: nil,
                synthesisSourceHash: nil,
                tags: theme.tags,
                thoughtIDs: theme.thoughtIDs,
                colorHex: ThoughtCategoryColor.hex(for: theme.title),
                createdAt: theme.createdAt,
                updatedAt: theme.updatedAt,
                isStale: true
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
            synthesisMarkdown: nil,
            synthesizedAt: nil,
            synthesisSourceHash: nil,
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

private func actionItemSort(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
    switch (lhs.dueAt, rhs.dueAt) {
    case let (lhsDue?, rhsDue?):
        if lhsDue != rhsDue {
            return lhsDue < rhsDue
        }
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    case (nil, nil):
        break
    }

    return lhs.createdAt > rhs.createdAt
}

final class ActionReminderScheduler {
    static let shared = ActionReminderScheduler()

    private let notificationPrefix = "action-reminder-"

    private init() {}

    func sync(actionItems: [ActionItem], settings: TodoSettings) {
        Task {
            await schedule(actionItems: actionItems, settings: settings)
        }
    }

    func syncAll(actionItems: [ActionItem], settings: TodoSettings) {
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let managedIdentifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(notificationPrefix) }

            center.removePendingNotificationRequests(withIdentifiers: managedIdentifiers)
            await schedule(actionItems: actionItems, settings: settings)
        }
    }

    func cancel(actionItemIDs: [UUID]) {
        let identifiers = actionItemIDs.map { notificationIdentifier(for: $0) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func schedule(actionItems: [ActionItem], settings: TodoSettings) async {
        let enabled = await MainActor.run { settings.remindersEnabled }
        let leadTimeMinutes = await MainActor.run { settings.reminderLeadTimeMinutes }
        guard enabled else {
            cancel(actionItemIDs: actionItems.map(\.id))
            return
        }

        let schedulableItems = actionItems.filter { !$0.isDone && $0.dueAt != nil }
        guard !schedulableItems.isEmpty else {
            return
        }

        let isAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        guard isAuthorized else {
            return
        }

        for item in schedulableItems {
            await schedule(actionItem: item, leadTimeMinutes: leadTimeMinutes)
        }
    }

    private func schedule(actionItem: ActionItem, leadTimeMinutes: Int) async {
        guard let dueAt = actionItem.dueAt else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let identifier = notificationIdentifier(for: actionItem.id)
        let reminderAt = dueAt.addingTimeInterval(-TimeInterval(leadTimeMinutes * 60))
        let now = Date()
        let content = notificationContent(for: actionItem, dueAt: dueAt)

        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        guard reminderAt > now else {
            await deliverImmediateReminderIfNeeded(
                identifier: identifier,
                content: content,
                dueAt: dueAt,
                now: now,
                leadTimeMinutes: leadTimeMinutes
            )
            return
        }

        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminderAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        try? await center.add(request)
    }

    private func deliverImmediateReminderIfNeeded(
        identifier: String,
        content: UNNotificationContent,
        dueAt: Date,
        now: Date,
        leadTimeMinutes: Int
    ) async {
        let leadTime = TimeInterval(leadTimeMinutes * 60)
        guard dueAt.timeIntervalSince(now) <= leadTime else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        guard !delivered.contains(where: { $0.request.identifier == identifier }) else {
            return
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    private func notificationContent(for actionItem: ActionItem, dueAt: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "TODO due \(DateFormatter.actionReminderDueDate.string(from: dueAt))"
        content.body = actionItem.title
        content.sound = .default
        content.userInfo = ["actionItemID": actionItem.id.uuidString]
        return content
    }

    private func notificationIdentifier(for actionItemID: UUID) -> String {
        "\(notificationPrefix)\(actionItemID.uuidString)"
    }
}

private extension DateFormatter {
    static let actionReminderDueDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
