import Combine
import Foundation

@MainActor
final class ThoughtStore: ObservableObject {
    static let shared = ThoughtStore()

    @Published private(set) var thoughts: [Thought] = []
    @Published private(set) var themes: [Theme] = []
    @Published private(set) var dailyDigests: [DailyDigest] = []
    @Published private(set) var actionItems: [ActionItem] = []

    private let thoughtsURL: URL
    private let themesURL: URL
    private let dailyDigestsURL: URL
    private let actionItemsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directoryURL = supportURL.appendingPathComponent("ThoughtNotch", isDirectory: true)
        thoughtsURL = directoryURL.appendingPathComponent("thoughts.json")
        themesURL = directoryURL.appendingPathComponent("themes.json")
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
        let thought = Thought(
            text: text,
            createdAt: Date()
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
        dailyDigests = loadArray(from: dailyDigestsURL, fallback: [])
            .sorted { $0.day > $1.day }
        actionItems = loadArray(from: actionItemsURL, fallback: [])
            .sorted { $0.createdAt > $1.createdAt }
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
}
