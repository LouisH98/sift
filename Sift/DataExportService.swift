import Foundation

struct SiftDataExportResult {
    let folderURL: URL
    let bundleURL: URL
    let pagesMarkdownURL: URL
    let thoughtsMarkdownURL: URL
    let todosMarkdownURL: URL
}

struct SiftDataExportBundle: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let thoughts: [Thought]
    let themes: [Theme]
    let pages: [ThoughtPage]
    let dailyDigests: [DailyDigest]
    let actionItems: [ActionItem]
}

@MainActor
struct DataExportService {
    static let shared = DataExportService(
        applicationSupportDirectory: AppIdentity.applicationSupportDirectory()
    )

    let applicationSupportDirectory: URL

    private var exportsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    func exportCurrentStore() throws -> SiftDataExportResult {
        try exportCurrentStore(ThoughtStore.shared)
    }

    func exportCurrentStore(_ store: ThoughtStore) throws -> SiftDataExportResult {
        try export(
            bundle: SiftDataExportBundle(
                schemaVersion: 1,
                exportedAt: Date(),
                thoughts: store.thoughts,
                themes: store.themes,
                pages: store.pages,
                dailyDigests: store.dailyDigests,
                actionItems: store.actionItems
            )
        )
    }

    func export(bundle: SiftDataExportBundle) throws -> SiftDataExportResult {
        try export(bundle: bundle, to: exportsDirectory)
    }

    func export(bundle: SiftDataExportBundle, to destinationDirectory: URL) throws -> SiftDataExportResult {
        let fileManager = FileManager.default
        let folderURL = destinationDirectory
            .appendingPathComponent("Sift Export \(Self.folderTimestampFormatter.string(from: bundle.exportedAt))", isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let bundleURL = folderURL.appendingPathComponent("sift-export.json")
        try encoder.encode(bundle).write(to: bundleURL, options: [.atomic])

        let pagesMarkdownURL = folderURL.appendingPathComponent("pages.md")
        let thoughtsMarkdownURL = folderURL.appendingPathComponent("thoughts.md")
        let todosMarkdownURL = folderURL.appendingPathComponent("todos.md")

        try pagesMarkdown(for: bundle).write(to: pagesMarkdownURL, atomically: true, encoding: .utf8)
        try thoughtsMarkdown(for: bundle).write(to: thoughtsMarkdownURL, atomically: true, encoding: .utf8)
        try todosMarkdown(for: bundle).write(to: todosMarkdownURL, atomically: true, encoding: .utf8)

        return SiftDataExportResult(
            folderURL: folderURL,
            bundleURL: bundleURL,
            pagesMarkdownURL: pagesMarkdownURL,
            thoughtsMarkdownURL: thoughtsMarkdownURL,
            todosMarkdownURL: todosMarkdownURL
        )
    }

    private func pagesMarkdown(for bundle: SiftDataExportBundle) -> String {
        let pagesByID = Dictionary(uniqueKeysWithValues: bundle.pages.map { ($0.id, $0) })
        let thoughtsByID = Dictionary(uniqueKeysWithValues: bundle.thoughts.map { ($0.id, $0) })
        var output = exportHeader(title: "Sift Pages", exportedAt: bundle.exportedAt)

        for page in bundle.pages.sorted(by: pageSort) {
            output += "\n## \(escapedMarkdownHeading(page.title))\n\n"
            output += "- ID: \(page.id.uuidString)\n"
            if let parent = page.parentID.flatMap({ pagesByID[$0] }) {
                output += "- Parent: \(parent.title)\n"
            }
            if !page.tags.isEmpty {
                output += "- Tags: \(page.tags.joined(separator: ", "))\n"
            }
            output += "- Created: \(Self.displayDateFormatter.string(from: page.createdAt))\n"
            output += "- Updated: \(Self.displayDateFormatter.string(from: page.updatedAt))\n"

            if !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += "\n### Summary\n\n\(page.summary)\n"
            }
            if !page.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output += "\n### Body\n\n\(page.bodyMarkdown)\n"
            }
            if let synthesis = page.synthesisMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !synthesis.isEmpty {
                output += "\n### Synthesis\n\n\(synthesis)\n"
            }

            let pageThoughts = page.thoughtIDs.compactMap { thoughtsByID[$0] }
            if !pageThoughts.isEmpty {
                output += "\n### Thoughts\n\n"
                for thought in pageThoughts.sorted(by: { $0.createdAt > $1.createdAt }) {
                    output += "- \(Self.displayDateFormatter.string(from: thought.createdAt)): \(oneLine(thought.title ?? thought.distilled ?? thought.text))\n"
                }
            }
        }

        return output
    }

    private func thoughtsMarkdown(for bundle: SiftDataExportBundle) -> String {
        var output = exportHeader(title: "Sift Thoughts", exportedAt: bundle.exportedAt)

        for thought in bundle.thoughts.sorted(by: { $0.createdAt > $1.createdAt }) {
            output += "\n## \(escapedMarkdownHeading(thought.title ?? Self.displayDateFormatter.string(from: thought.createdAt)))\n\n"
            output += "- ID: \(thought.id.uuidString)\n"
            output += "- Created: \(Self.displayDateFormatter.string(from: thought.createdAt))\n"
            if let category = thought.category, !category.isEmpty {
                output += "- Page: \(category)\n"
            }
            if !thought.tags.isEmpty {
                output += "- Tags: \(thought.tags.joined(separator: ", "))\n"
            }
            if let processedAt = thought.processedAt {
                output += "- Processed: \(Self.displayDateFormatter.string(from: processedAt))\n"
            }
            if let processingError = thought.processingError, !processingError.isEmpty {
                output += "- Processing error: \(processingError)\n"
            }

            if let distilled = thought.distilled?.trimmingCharacters(in: .whitespacesAndNewlines), !distilled.isEmpty {
                output += "\n### Distilled\n\n\(distilled)\n"
            }
            output += "\n### Original\n\n\(thought.text)\n"
        }

        return output
    }

    private func todosMarkdown(for bundle: SiftDataExportBundle) -> String {
        let thoughtsByID = Dictionary(uniqueKeysWithValues: bundle.thoughts.map { ($0.id, $0) })
        var output = exportHeader(title: "Sift Todos", exportedAt: bundle.exportedAt)

        for item in bundle.actionItems.sorted(by: todoSort) {
            output += "\n## \(item.isDone ? "[x]" : "[ ]") \(escapedMarkdownHeading(item.title))\n\n"
            output += "- ID: \(item.id.uuidString)\n"
            output += "- Created: \(Self.displayDateFormatter.string(from: item.createdAt))\n"
            if let dueDate = item.dueDate {
                var due = Self.displayDateFormatter.string(from: dueDate)
                if let dueTime = item.dueTime, !dueTime.isEmpty {
                    due += " \(dueTime)"
                }
                output += "- Due: \(due)\n"
            }
            if let completedAt = item.completedAt {
                output += "- Completed: \(Self.displayDateFormatter.string(from: completedAt))\n"
            }
            if let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                output += "\n\(detail)\n"
            }
            if let sourceThought = thoughtsByID[item.thoughtID] {
                output += "\nSource thought: \(oneLine(sourceThought.title ?? sourceThought.distilled ?? sourceThought.text))\n"
            }
        }

        return output
    }

    private func exportHeader(title: String, exportedAt: Date) -> String {
        """
        # \(title)

        Exported: \(Self.displayDateFormatter.string(from: exportedAt))
        """
    }

    private func escapedMarkdownHeading(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    private func todoSort(_ lhs: ActionItem, _ rhs: ActionItem) -> Bool {
        switch (lhs.isDone, rhs.isDone) {
        case (false, true):
            return true
        case (true, false):
            return false
        default:
            break
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

    private static let folderTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()
}
