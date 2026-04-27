import Foundation

struct Thought: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date
    var distilled: String?
    var title: String?
    var tags: [String]
    var category: String?
    var themeID: UUID?
    var pageID: UUID?
    var themeHint: String?
    var themeHintPrefixLength: Int?
    var themeHintColorHex: String?
    var linkedThoughtIDs: [UUID]
    var processedAt: Date?
    var processingError: String?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        distilled: String? = nil,
        title: String? = nil,
        tags: [String] = [],
        category: String? = nil,
        themeID: UUID? = nil,
        pageID: UUID? = nil,
        themeHint: String? = nil,
        themeHintPrefixLength: Int? = nil,
        themeHintColorHex: String? = nil,
        linkedThoughtIDs: [UUID] = [],
        processedAt: Date? = nil,
        processingError: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.distilled = distilled
        self.title = title
        self.tags = tags
        self.category = category
        self.themeID = themeID
        self.pageID = pageID
        self.themeHint = themeHint
        self.themeHintPrefixLength = themeHintPrefixLength
        self.themeHintColorHex = themeHintColorHex
        self.linkedThoughtIDs = linkedThoughtIDs
        self.processedAt = processedAt
        self.processingError = processingError
    }
}

struct ThoughtPage: Codable, Identifiable, Hashable {
    let id: UUID
    var parentID: UUID?
    var title: String
    var summary: String
    var bodyMarkdown: String
    var synthesisMarkdown: String?
    var synthesizedAt: Date?
    var synthesisSourceHash: String?
    var tags: [String]
    var thoughtIDs: [UUID]
    var colorHex: String?
    var createdAt: Date
    var updatedAt: Date
    var isStale: Bool
}

struct Theme: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var summary: String
    var tags: [String]
    var thoughtIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
}

struct DailyDigest: Codable, Identifiable, Hashable {
    let id: UUID
    var day: Date
    var title: String
    var summary: String
    var highlights: [String]
    var actionItemIDs: [UUID]
    var thoughtIDs: [UUID]
    var updatedAt: Date
}

struct ActionItem: Codable, Identifiable, Hashable {
    let id: UUID
    let thoughtID: UUID
    var themeID: UUID?
    var title: String
    var detail: String?
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
    var dueAt: Date?
}

struct ThoughtThemeHint: Equatable {
    let title: String
    let prefixLength: Int
}

enum ThoughtPrefixParser {
    static func themeHint(in text: String) -> ThoughtThemeHint? {
        guard let colonIndex = text.firstIndex(of: ":") else {
            return nil
        }

        let prefix = text[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix.count <= 64 else {
            return nil
        }

        guard prefix.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        let disallowedCharacters = CharacterSet(charactersIn: ".!?;")
        guard prefix.rangeOfCharacter(from: disallowedCharacters) == nil else {
            return nil
        }

        let prefixLength = text.distance(from: text.startIndex, to: text.index(after: colonIndex))
        return ThoughtThemeHint(title: prefix, prefixLength: prefixLength)
    }
}

enum ThoughtCategoryColor {
    static let palette = [
        "#FF6B6B",
        "#F59E0B",
        "#FACC15",
        "#34D399",
        "#2DD4BF",
        "#38BDF8",
        "#60A5FA",
        "#A78BFA",
        "#F472B6",
        "#FB7185",
        "#A3E635",
        "#C084FC"
    ]

    static func hex(for title: String) -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return palette[0]
        }

        let seed = normalized.unicodeScalars.reduce(UInt32(2166136261)) { partial, scalar in
            (partial ^ scalar.value) &* 16777619
        }

        return palette[Int(seed % UInt32(palette.count))]
    }
}

struct ReorganizationProposal: Codable, Hashable, Identifiable {
    var id: String {
        pages.map(\.id).joined(separator: "|") + deletedPageIDs.map(\.uuidString).joined(separator: "|")
    }

    var notes: [String]
    var deletedPageIDs: [UUID]
    var pages: [ProposedThoughtPage]
}

struct ProposedThoughtPage: Codable, Identifiable, Hashable {
    var id: String
    var existingPageID: UUID?
    var parentID: String?
    var title: String
    var summary: String
    var bodyMarkdown: String
    var tags: [String]
    var thoughtIDs: [UUID]
}
