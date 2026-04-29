import CryptoKit
import Combine
import Foundation
import NaturalLanguage

@MainActor
final class ThoughtEmbeddingIndex: ObservableObject {
    static let shared = ThoughtEmbeddingIndex()

    private struct Key: Hashable {
        let kind: ThoughtChatSource.Kind
        let id: UUID
    }

    private struct Record: Codable {
        let kind: String
        let id: UUID
        let contentHash: String
        let vector: [Double]
        let updatedAt: Date
    }

    struct Status {
        let isAvailable: Bool
        let recordCount: Int
        let expectedRecordCount: Int
        let missingRecordCount: Int
        let isRebuilding: Bool
        let rebuiltCount: Int
        let rebuildTotal: Int
        let lastRebuiltAt: Date?
        let lastError: String?
    }

    @Published private var revision = 0
    @Published private(set) var isRebuilding = false
    @Published private(set) var rebuiltCount = 0
    @Published private(set) var rebuildTotal = 0
    @Published private(set) var lastRebuiltAt: Date?
    @Published private(set) var lastError: String?

    private let indexURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var records: [Key: Record] = [:]

    func status(store: ThoughtStore) -> Status {
        let expectedKeys = liveKeys(store: store)
        let validRecordCount = records.keys.filter { expectedKeys.contains($0) }.count

        return Status(
            isAvailable: Self.embedding?.vector(for: "semantic search status") != nil,
            recordCount: validRecordCount,
            expectedRecordCount: expectedKeys.count,
            missingRecordCount: max(0, expectedKeys.count - validRecordCount),
            isRebuilding: isRebuilding,
            rebuiltCount: rebuiltCount,
            rebuildTotal: rebuildTotal,
            lastRebuiltAt: lastRebuiltAt,
            lastError: lastError
        )
    }

    private init() {
        indexURL = AppIdentity.applicationSupportDirectory().appendingPathComponent("semantic-index.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func rebuildAll(store: ThoughtStore) async {
        guard !isRebuilding else {
            return
        }

        guard Self.embedding?.vector(for: "semantic search status") != nil else {
            lastError = "Apple sentence embeddings are unavailable on this Mac."
            revision += 1
            return
        }

        isRebuilding = true
        rebuiltCount = 0
        rebuildTotal = store.thoughts.count + store.pages.count + store.actionItems.count
        lastError = nil
        revision += 1

        records.removeAll()

        for thought in store.thoughts {
            _ = upsertThought(thought, store: store, shouldSave: false)
            await advanceRebuildProgress()
        }

        for page in store.pages {
            _ = upsertPage(page, shouldSave: false)
            await advanceRebuildProgress()
        }

        for item in store.actionItems {
            _ = upsertActionItem(item, store: store, shouldSave: false)
            await advanceRebuildProgress()
        }

        save()
        lastRebuiltAt = Date()
        isRebuilding = false
        revision += 1
    }

    func refreshAll(store: ThoughtStore) {
        guard Self.embedding != nil else {
            return
        }

        var validKeys = Set<Key>()
        var didChange = false

        for thought in store.thoughts {
            let key = Key(kind: .thought, id: thought.id)
            validKeys.insert(key)
            didChange = upsertThought(thought, store: store, shouldSave: false) || didChange
        }

        for page in store.pages {
            let key = Key(kind: .page, id: page.id)
            validKeys.insert(key)
            didChange = upsertPage(page, shouldSave: false) || didChange
        }

        for item in store.actionItems {
            let key = Key(kind: .actionItem, id: item.id)
            validKeys.insert(key)
            didChange = upsertActionItem(item, store: store, shouldSave: false) || didChange
        }

        let staleKeys = records.keys.filter { !validKeys.contains($0) }
        if !staleKeys.isEmpty {
            staleKeys.forEach { records.removeValue(forKey: $0) }
            didChange = true
        }

        if didChange {
            save()
        } else {
            revision += 1
        }
    }

    @discardableResult
    func upsertThought(_ thought: Thought, store: ThoughtStore) -> Bool {
        upsertThought(thought, store: store, shouldSave: true)
    }

    @discardableResult
    func upsertPage(_ page: ThoughtPage) -> Bool {
        upsertPage(page, shouldSave: true)
    }

    @discardableResult
    func upsertActionItem(_ item: ActionItem, store: ThoughtStore) -> Bool {
        upsertActionItem(item, store: store, shouldSave: true)
    }

    func remove(kind: ThoughtChatSource.Kind, id: UUID) {
        guard records.removeValue(forKey: Key(kind: kind, id: id)) != nil else {
            return
        }

        save()
    }

    func remove(kind: ThoughtChatSource.Kind, ids: some Sequence<UUID>) {
        var didChange = false
        for id in ids {
            if records.removeValue(forKey: Key(kind: kind, id: id)) != nil {
                didChange = true
            }
        }

        if didChange {
            save()
        }
    }

    func search(query: String, store: ThoughtStore, limit: Int) -> [ThoughtChatSource]? {
        let cleanQuery = cleanWhitespace(query)
        guard !cleanQuery.isEmpty,
              let embedding = Self.embedding,
              let queryVector = embedding.vector(for: cleanQuery) else {
            return nil
        }

        let matches = records.values
            .compactMap { record -> ThoughtChatSource? in
                let score = cosineSimilarity(queryVector, record.vector)
                guard score > 0 else {
                    return nil
                }

                return source(for: record, score: score, store: store)
            }
            .sorted(by: rankedBefore)
            .prefix(limit)

        let sources = Array(matches)
        guard sources.contains(where: { $0.score >= 0.28 }) else {
            return nil
        }

        return sources
    }

    private func upsertThought(_ thought: Thought, store: ThoughtStore, shouldSave: Bool) -> Bool {
        let text = searchableText(for: thought, store: store)
        return upsert(kind: .thought, id: thought.id, text: text, shouldSave: shouldSave)
    }

    private func upsertPage(_ page: ThoughtPage, shouldSave: Bool) -> Bool {
        let text = searchableText(for: page)
        return upsert(kind: .page, id: page.id, text: text, shouldSave: shouldSave)
    }

    private func upsertActionItem(_ item: ActionItem, store: ThoughtStore, shouldSave: Bool) -> Bool {
        let text = searchableText(for: item, store: store)
        return upsert(kind: .actionItem, id: item.id, text: text, shouldSave: shouldSave)
    }

    private func upsert(kind: ThoughtChatSource.Kind, id: UUID, text: String, shouldSave: Bool) -> Bool {
        let cleanText = cleanWhitespace(text)
        let key = Key(kind: kind, id: id)
        guard !cleanText.isEmpty else {
            let didRemove = records.removeValue(forKey: key) != nil
            if didRemove, shouldSave {
                save()
            }
            return didRemove
        }

        let hash = stableHash(cleanText)
        if records[key]?.contentHash == hash {
            return false
        }

        guard let vector = Self.embedding?.vector(for: String(cleanText.prefix(4_000))) else {
            return false
        }

        records[key] = Record(
            kind: kind.rawValue,
            id: id,
            contentHash: hash,
            vector: vector,
            updatedAt: Date()
        )

        if shouldSave {
            save()
        }

        return true
    }

    private func advanceRebuildProgress() async {
        rebuiltCount += 1
        revision += 1
        await Task.yield()
    }

    private func liveKeys(store: ThoughtStore) -> Set<Key> {
        Set(
            store.thoughts.map { Key(kind: .thought, id: $0.id) }
                + store.pages.map { Key(kind: .page, id: $0.id) }
                + store.actionItems.map { Key(kind: .actionItem, id: $0.id) }
        )
    }

    private func source(for record: Record, score: Double, store: ThoughtStore) -> ThoughtChatSource? {
        guard let kind = ThoughtChatSource.Kind(rawValue: record.kind) else {
            return nil
        }

        switch kind {
        case .thought:
            guard let thought = store.thought(with: record.id) else {
                return nil
            }

            return ThoughtChatSource(
                id: thought.id,
                kind: .thought,
                title: thought.title ?? thought.text,
                snippet: bestSnippet([thought.text, thought.distilled ?? "", thought.tags.joined(separator: " ")]),
                date: thought.createdAt,
                score: score + recencyBoost(for: thought.createdAt) * 0.04
            )

        case .page:
            guard let page = store.page(with: record.id) else {
                return nil
            }

            return ThoughtChatSource(
                id: page.id,
                kind: .page,
                title: page.title,
                snippet: bestSnippet([page.summary, page.synthesisMarkdown ?? "", page.bodyMarkdown]),
                date: page.updatedAt,
                score: score + recencyBoost(for: page.updatedAt) * 0.02
            )

        case .actionItem:
            guard let item = store.actionItems.first(where: { $0.id == record.id }) else {
                return nil
            }

            return ThoughtChatSource(
                id: item.id,
                kind: .actionItem,
                title: item.title,
                snippet: actionItemSnippet(item),
                date: item.dueDate ?? item.createdAt,
                score: score + dueBoost(for: item) * 0.05
            )

        case .web:
            return nil
        }
    }

    private func searchableText(for thought: Thought, store: ThoughtStore) -> String {
        let pageTitle = store.page(with: thought.pageID)?.title ?? ""
        return [
            thought.title ?? "",
            pageTitle,
            thought.category ?? "",
            thought.themeHint ?? "",
            thought.tags.joined(separator: " "),
            thought.text,
            thought.distilled ?? ""
        ].joined(separator: "\n")
    }

    private func searchableText(for page: ThoughtPage) -> String {
        [
            page.title,
            page.tags.joined(separator: " "),
            page.summary,
            page.synthesisMarkdown ?? "",
            page.bodyMarkdown
        ].joined(separator: "\n")
    }

    private func searchableText(for item: ActionItem, store: ThoughtStore) -> String {
        let linkedThought = store.thought(with: item.thoughtID)
        return [
            item.title,
            item.detail ?? "",
            item.isDone ? "done completed" : "open todo",
            actionItemDueText(item),
            linkedThought?.title ?? "",
            linkedThought?.text ?? "",
            linkedThought?.distilled ?? ""
        ].joined(separator: "\n")
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

        let date = DateFormatter.embeddingIndexDueDate.string(from: dueDate)
        guard let dueTime = item.dueTime, !dueTime.isEmpty else {
            return "Due \(date)"
        }

        return "Due \(date) at \(dueTime)"
    }

    private func bestSnippet(_ values: [String]) -> String {
        let best = values
            .map { cleanWhitespace($0) }
            .first { !$0.isEmpty } ?? ""

        return truncate(best, maxLength: 220)
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }

        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0

        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else {
            return 0
        }

        return dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    private func stableHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

    private func load() {
        do {
            guard FileManager.default.fileExists(atPath: indexURL.path) else {
                return
            }

            let data = try Data(contentsOf: indexURL)
            let loadedRecords = try decoder.decode([Record].self, from: data)
            records = Dictionary(
                uniqueKeysWithValues: loadedRecords.compactMap { record in
                    guard let kind = ThoughtChatSource.Kind(rawValue: record.kind), kind != .web else {
                        return nil
                    }

                    return (Key(kind: kind, id: record.id), record)
                }
            )
        } catch {
            NSLog("Sift failed to load semantic index: \(error.localizedDescription)")
            records = [:]
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let data = try encoder.encode(records.values.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind < rhs.kind
                }

                return lhs.id.uuidString < rhs.id.uuidString
            })
            try data.write(to: indexURL, options: [.atomic])
            revision += 1
        } catch {
            NSLog("Sift failed to save semantic index: \(error.localizedDescription)")
            lastError = error.localizedDescription
            revision += 1
        }
    }

    private static var embedding: NLEmbedding? {
        NLEmbedding.sentenceEmbedding(for: .english)
    }
}

private extension DateFormatter {
    static let embeddingIndexDueDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
