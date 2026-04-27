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
        self.linkedThoughtIDs = linkedThoughtIDs
        self.processedAt = processedAt
        self.processingError = processingError
    }
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
