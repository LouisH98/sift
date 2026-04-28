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
    var priority: Int? = nil
    var createdAt: Date
    var completedAt: Date?
    var dueDate: Date?
    var dueTime: String?

    var exactDueAt: Date? {
        Self.combinedDueAt(dueDate: dueDate, dueTime: dueTime)
    }

    var sortDueAt: Date? {
        if let exactDueAt {
            return exactDueAt
        }

        guard let dueDate else {
            return nil
        }

        return Calendar.current.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: dueDate
        )
    }

    var hasDueTime: Bool {
        exactDueAt != nil
    }

    var isDueOverdue: Bool {
        if let exactDueAt {
            return exactDueAt < Date()
        }

        guard let dueDate else {
            return false
        }

        return Calendar.current.startOfDay(for: dueDate) < Calendar.current.startOfDay(for: Date())
    }

    static func combinedDueAt(dueDate: Date?, dueTime: String?) -> Date? {
        guard
            let dueDate,
            let dueTime,
            let time = timeComponents(from: dueTime)
        else {
            return nil
        }

        var calendar = Calendar.current
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: dueDate)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        components.calendar = calendar
        components.timeZone = .current
        return calendar.date(from: components)
    }

    static func timeComponents(from dueTime: String) -> (hour: Int, minute: Int)? {
        let parts = dueTime.split(separator: ":")
        guard
            parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            return nil
        }

        return (hour, minute)
    }

    init(
        id: UUID,
        thoughtID: UUID,
        themeID: UUID?,
        title: String,
        detail: String?,
        isDone: Bool,
        priority: Int? = nil,
        createdAt: Date,
        completedAt: Date?,
        dueDate: Date?,
        dueTime: String?
    ) {
        self.id = id
        self.thoughtID = thoughtID
        self.themeID = themeID
        self.title = title
        self.detail = detail
        self.isDone = isDone
        self.priority = priority
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.dueTime = dueTime
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case thoughtID
        case themeID
        case title
        case detail
        case isDone
        case priority
        case createdAt
        case completedAt
        case dueDate
        case dueTime
        case dueAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        thoughtID = try container.decode(UUID.self, forKey: .thoughtID)
        themeID = try container.decodeIfPresent(UUID.self, forKey: .themeID)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)

        let legacyDueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
            ?? legacyDueAt.map { Calendar.current.startOfDay(for: $0) }

        if let storedDueTime = try container.decodeIfPresent(String.self, forKey: .dueTime) {
            dueTime = storedDueTime
        } else if let legacyDueAt {
            let components = Calendar.current.dateComponents([.hour, .minute], from: legacyDueAt)
            if let hour = components.hour, let minute = components.minute {
                dueTime = String(format: "%02d:%02d", hour, minute)
            } else {
                dueTime = nil
            }
        } else {
            dueTime = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(thoughtID, forKey: .thoughtID)
        try container.encodeIfPresent(themeID, forKey: .themeID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(isDone, forKey: .isDone)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encodeIfPresent(dueTime, forKey: .dueTime)
    }
}

struct ThoughtThemeHint: Equatable {
    let title: String
    let prefixLength: Int
}

struct ThoughtTodoHint: Equatable {
    let prefixLength: Int
}

enum ThoughtPrefixParser {
    static func todoHint(in text: String) -> ThoughtTodoHint? {
        guard let prefixEnd = todoPrefixEnd(in: text) else {
            return nil
        }

        return ThoughtTodoHint(prefixLength: text.distance(from: text.startIndex, to: prefixEnd))
    }

    static func themeHint(in text: String) -> ThoughtThemeHint? {
        let prefixStart = todoPrefixEnd(in: text) ?? text.startIndex
        guard let colonIndex = text[prefixStart...].firstIndex(of: ":") else {
            return nil
        }

        let prefix = text[prefixStart..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidThemePrefix(prefix) else {
            return nil
        }

        let prefixLength = text.distance(from: text.startIndex, to: text.index(after: colonIndex))
        return ThoughtThemeHint(title: prefix, prefixLength: prefixLength)
    }

    static func todoBody(in text: String) -> String {
        let contentStart = todoPrefixEnd(in: text) ?? text.startIndex
        let remainder = text[contentStart...]

        guard let colonIndex = remainder.firstIndex(of: ":") else {
            return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let prefix = remainder[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidThemePrefix(prefix) else {
            return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyStart = text.index(after: colonIndex)
        return String(text[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func todoPrefixEnd(in text: String) -> String.Index? {
        guard text.first == "!" else {
            return nil
        }

        var index = text.index(after: text.startIndex)
        while index < text.endIndex, text[index].isWhitespace, text[index] != "\n" {
            index = text.index(after: index)
        }
        return index
    }

    private static func isValidThemePrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty, prefix.count <= 64 else {
            return false
        }

        guard prefix.rangeOfCharacter(from: .newlines) == nil else {
            return false
        }

        let disallowedCharacters = CharacterSet(charactersIn: ".!?;")
        guard prefix.rangeOfCharacter(from: disallowedCharacters) == nil else {
            return false
        }

        return true
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
