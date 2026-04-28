import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@MainActor
struct AppleFoundationModelsProvider: ThoughtAIProvider {
    private let store: ThoughtStore
    private let model = SystemLanguageModel.default
    private let foundationModelsPromptVersion = "foundation-models-v1"

    init(store: ThoughtStore) {
        self.store = store
    }

    static func status() -> ThoughtAIProviderStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            let language = Locale.current.language
            guard model.supportedLanguages.contains(language) else {
                return ThoughtAIProviderStatus(
                    title: "Current language unsupported",
                    message: "Apple Foundation Models is ready, but it does not support \(currentLanguageDescription). Change macOS language or use the OpenAI-compatible provider.",
                    isAvailable: false
                )
            }

            return ThoughtAIProviderStatus(
                title: "Apple Foundation Models ready",
                message: "Uses the on-device Apple Intelligence system language model with \(currentLanguageDescription).",
                isAvailable: true
            )
        case .unavailable(.deviceNotEligible):
            return ThoughtAIProviderStatus(
                title: "This Mac is not eligible",
                message: "Apple Foundation Models requires a Mac that supports Apple Intelligence.",
                isAvailable: false
            )
        case .unavailable(.appleIntelligenceNotEnabled):
            return ThoughtAIProviderStatus(
                title: "Apple Intelligence is off",
                message: "Turn on Apple Intelligence in System Settings to use local generation.",
                isAvailable: false
            )
        case .unavailable(.modelNotReady):
            return ThoughtAIProviderStatus(
                title: "Model is not ready",
                message: "Apple Intelligence may still be downloading or preparing the on-device model.",
                isAvailable: false
            )
        case .unavailable:
            return ThoughtAIProviderStatus(
                title: "Foundation Models unavailable",
                message: "The on-device model is unavailable for an unknown system reason.",
                isAvailable: false
            )
        @unknown default:
            return ThoughtAIProviderStatus(
                title: "Foundation Models unavailable",
                message: "The on-device model returned an unknown availability state.",
                isAvailable: false
            )
        }
    }

    func process(input: ThoughtProcessingInput) async throws -> ThoughtProcessingOutput {
        try ensureAvailable()
        let instructions = """
        You organize a private thought-capture notebook. Respond in English. Keep meaning intact and prefer notebook classification unless the raw thought is clearly asking someone to do something. Do not create action items for observations, ideas, memories, references, feelings, notes, or general plans. Extract date-only due dates separately from explicit due times. Version: \(foundationModelsPromptVersion).
        """
        let prompt = foundationProcessingPrompt(input.prompt)

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: shortPrompt(prompt),
                generating: FoundationThoughtProcessingOutput.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(temperature: 0.1)
            )
            return normalizedProcessingOutput(response.content.output, sourcePrompt: input.prompt)
        } catch {
            let mappedError = map(error)
            guard isUnsupportedLanguageOrLocale(mappedError) else {
                throw mappedError
            }

            do {
                let retrySession = LanguageModelSession(model: model, instructions: instructions)
                let response = try await retrySession.respond(
                    to: englishOnlyPrompt(prompt),
                    generating: FoundationThoughtProcessingOutput.self,
                    includeSchemaInPrompt: true,
                    options: GenerationOptions(temperature: 0.1)
                )
                return normalizedProcessingOutput(response.content.output, sourcePrompt: input.prompt)
            } catch {
                throw map(error)
            }
        }
    }

    func reorganize(input: ThoughtReorganizationInput) async throws -> ReorganizationProposal {
        try ensureAvailable()
        let chunks = chunk(input.prompt, maxCharacters: 10_000)
        var chunkSummaries: [String] = []

        if chunks.count > 1 {
            for chunk in chunks {
                let summary = try await generateRawText(
                    instructions: "Summarize this notebook reorganization context into compact facts, preserving page IDs, thought IDs, and proposed grouping signals.",
                    prompt: chunk
                )
                chunkSummaries.append(summary)
            }
        }

        let prompt = chunks.count == 1 ? input.prompt : """
        Notebook reorganization summaries:
        \(chunkSummaries.joined(separator: "\n\n"))

        Final instructions:
        Return one complete proposed page tree. Preserve all IDs visible in the summaries.
        """

        let session = LanguageModelSession(
            model: model,
            tools: notebookTools(),
            instructions: """
            You reorganize a private thought notebook. Respond in English. Preserve raw thought IDs, propose a clear hierarchical page tree, and keep summaries concise. Use notebook tools when more local context is needed. Version: \(foundationModelsPromptVersion).
            """
        )
        do {
            let response = try await session.respond(
                to: shortPrompt(prompt),
                generating: FoundationReorganizationOutput.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(temperature: 0.2)
            )
            return response.content.proposal
        } catch {
            throw map(error)
        }
    }

    func synthesizePage(input: ThoughtSynthesisInput) async throws -> ThoughtSynthesisOutput {
        try ensureAvailable()
        let session = LanguageModelSession(
            model: model,
            tools: notebookTools(),
            instructions: """
            You synthesize private notebook pages into concise markdown. Respond in English. Integrate the notes into a useful default page view, preserve uncertainty, and do not invent facts. Use notebook tools when page context is missing. Version: \(foundationModelsPromptVersion).
            """
        )
        do {
            let response = try await session.respond(
                to: shortPrompt(input.prompt),
                generating: FoundationThoughtSynthesisOutput.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(temperature: 0.4)
            )
            return ThoughtSynthesisOutput(synthesisMarkdown: response.content.synthesisMarkdown)
        } catch {
            guard isDecodingFailure(error) else {
                throw map(error)
            }

            do {
                let markdown = try await generateRawText(
                    instructions: """
                    You synthesize private notebook pages into concise markdown. Respond in English. Integrate the notes into a useful default page view, preserve uncertainty, and do not invent facts.
                    """,
                    prompt: input.prompt
                )
                return ThoughtSynthesisOutput(synthesisMarkdown: markdown)
            } catch {
                throw map(error)
            }
        }
    }

    private func normalizedPageID(_ value: String) -> String {
        let trimmed = clean(value)
        guard let id = UUID(uuidString: trimmed), store.page(with: id) != nil else {
            return ""
        }

        return id.uuidString
    }

    private func normalizedPageParentID(pageID: String, parentID: String) -> String {
        let normalizedPageID = normalizedPageID(pageID)
        let trimmedParentID = clean(parentID)

        if let parentID = UUID(uuidString: trimmedParentID), store.page(with: parentID) != nil {
            return parentID.uuidString
        }

        if let pageID = UUID(uuidString: normalizedPageID),
           let existingPage = store.page(with: pageID),
           let existingParentID = existingPage.parentID {
            return existingParentID.uuidString
        }

        return ""
    }

    private func normalizedLinkedThoughtIDs(_ values: [String]) -> [String] {
        let knownThoughtIDs = Set(store.thoughts.map(\.id))
        return values.compactMap { value in
            guard let id = UUID(uuidString: clean(value)), knownThoughtIDs.contains(id) else {
                return nil
            }

            return id.uuidString
        }
    }

    private func isDecodingFailure(_ error: Error) -> Bool {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return false
        }

        if case .decodingFailure = generationError {
            return true
        }

        return false
    }

    func generateRawText(instructions: String, prompt: String) async throws -> String {
        try ensureAvailable()
        let session = LanguageModelSession(
            model: model,
            instructions: Instructions(instructions)
        )
        do {
            let response = try await session.respond(
                to: shortPrompt(prompt),
                options: GenerationOptions(temperature: 0.3)
            )
            return response.content
        } catch {
            throw map(error)
        }
    }

    func streamRawText(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    try ensureAvailable()
                    let session = LanguageModelSession(
                        model: model,
                        instructions: Instructions(instructions)
                    )
                    let stream = session.streamResponse(
                        to: shortPrompt(prompt),
                        options: GenerationOptions(temperature: 0.3)
                    )

                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: map(error))
                }
            }
        }
    }

    func suggestTags(for text: String) async throws -> [String] {
        try ensureAvailable()
        let tagModel = SystemLanguageModel(useCase: .contentTagging, guardrails: .default)
        let session = LanguageModelSession(
            model: tagModel,
            instructions: "Generate concise lowercase notebook tags. Return only tags."
        )
        do {
            let response = try await session.respond(
                to: "Suggest up to six tags for:\n\(shortPrompt(text))",
                generating: FoundationTagSuggestions.self,
                includeSchemaInPrompt: true,
                options: GenerationOptions(temperature: 0.1)
            )
            return response.content.tags
                .map(normalizeTag)
                .filter { !$0.isEmpty }
        } catch {
            throw map(error)
        }
    }

    func prewarm() {
        guard model.isAvailable else {
            return
        }

        let session = LanguageModelSession(
            model: model,
            instructions: "Prepare to organize short private notebook thoughts into typed structured output."
        )
        session.prewarm(promptPrefix: Prompt("New thought:"))
    }

    private func ensureAvailable() throws {
        guard model.isAvailable else {
            throw ThoughtAIProviderError.unavailable(Self.status().message)
        }

        guard model.supportedLanguages.contains(Locale.current.language) else {
            throw ThoughtAIProviderError.unsupportedLanguageOrLocale(Self.currentLanguageDescription)
        }
    }

    private func notebookTools() -> [any Tool] {
        [
            NotebookSearchTool(store: store),
            PageContextTool(store: store)
        ]
    }

    private func shortPrompt(_ prompt: String) -> String {
        String(sanitizedPrompt(prompt).prefix(12_000))
    }

    private func sanitizedPrompt(_ prompt: String) -> String {
        prompt
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("locale:")
                    && !trimmed.hasPrefix("timeZone:")
            }
            .joined(separator: "\n")
    }

    private func foundationProcessingPrompt(_ prompt: String) -> String {
        """
        \(prompt)

        Foundation Models stricter classification rules:
        - Use classification "notebook" by default.
        - Use classification "todo" or "both" only if raw text includes an imperative task, follow-up, reminder, commitment, request, or todoDirective is forced.
        - Return actionItems as [] unless the raw text itself contains a concrete task or todoDirective is forced.
        - When todoDirective is forced, treat the leading ! as a capture directive and omit it from titles, summaries, tags, and distilled prose.
        - Do not turn a general idea, note, observation, preference, or plan into an action item.
        - Set dueDate to YYYY-MM-DD if the raw text specifies or strongly implies a due date, including today, tomorrow, Friday, next week, by Friday, before Friday, due Friday, or a date.
        - Set dueTime to 24-hour HH:mm only if the raw text contains an explicit time-of-day signal like at 3pm, 14:30, noon, midnight, EOD, end of day, tonight, this afternoon, or this evening.
        - Never invent a default due time.
        """
    }

    private func englishOnlyPrompt(_ prompt: String) -> String {
        """
        Respond in English. If any provided text is not English, infer the intent and produce English output.

        \(shortPrompt(prompt))
        """
    }

    private func chunk(_ value: String, maxCharacters: Int) -> [String] {
        guard value.count > maxCharacters else {
            return [value]
        }

        var chunks: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            let end = value.index(start, offsetBy: maxCharacters, limitedBy: value.endIndex) ?? value.endIndex
            chunks.append(String(value[start..<end]))
            start = end
        }
        return chunks
    }

    private func normalizeTag(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    private func normalizedProcessingOutput(_ output: ThoughtProcessingOutput, sourcePrompt: String) -> ThoughtProcessingOutput {
        let sourceThought = rawThoughtText(from: sourcePrompt)
        let rawThought = sourceThought.lowercased()
        let isForcedTodo = forcedTodoDirective(from: sourcePrompt) || ThoughtPrefixParser.todoHint(in: sourceThought) != nil
        let hasTaskSignal = isForcedTodo || containsAny(
            rawThought,
            [
                "todo", "to do", "remind", "reminder", "follow up", "follow-up", "ask ", "call ",
                "email ", "send ", "schedule ", "book ", "buy ", "pay ", "submit ", "finish ",
                "complete ", "review ", "check ", "fix ", "update ", "make sure", "need to",
                "needs to", "i need", "i should", "we should", "remember to", "don't forget",
                "put ", "push ", "start ", "turn on ", "switch on ", "washing", "laundry"
            ]
        ) || rawThought.range(of: #"^(put|push|start|turn on|switch on|do|make|take|bring|pick up|drop off|wash|clean)\b"#, options: .regularExpression) != nil
        let hasExplicitTimeSignal = containsAny(
            rawThought,
            [
                "tonight", "eod", "end of day", "noon", "midnight", "this afternoon", "this evening",
                " at "
            ]
        ) || rawThought.range(of: #"\b\d{1,2}(:\d{2})?\s?(am|pm)\b|\b\d{1,2}(:\d{2})\b|\b(at|by|before)\s+\d{1,2}\b"#, options: .regularExpression) != nil

        let actionItems: [ThoughtProcessingOutput.Action]
        let classification: String
        let actionSourceThought = isForcedTodo ? ThoughtPrefixParser.todoBody(in: sourceThought) : sourceThought
        let inferredDueDate = hasDueDateSignal(in: rawThought) || hasExplicitTimeSignal ? inferredDueDate(from: sourceThought) : nil
        let inferredDueTime = hasExplicitTimeSignal ? inferredDueTime(from: sourceThought) : nil

        if hasTaskSignal {
            var normalizedActionItems = output.actionItems.map { action in
                let title = isForcedTodo ? normalizedForcedTodoTitle(action.title, fallback: actionSourceThought) : action.title
                return ThoughtProcessingOutput.Action(
                    title: title,
                    detail: action.detail,
                    dueDate: clean(action.dueDate).isEmpty ? formattedActionDate(inferredDueDate) : action.dueDate,
                    dueTime: hasExplicitTimeSignal ? (clean(action.dueTime).isEmpty ? inferredDueTime ?? "" : action.dueTime) : ""
                )
            }.filter { !clean($0.title).isEmpty }

            if normalizedActionItems.isEmpty, let fallbackAction = fallbackActionItem(
                for: actionSourceThought,
                inferredDueDate: inferredDueDate,
                inferredDueTime: inferredDueTime
            ) {
                normalizedActionItems = [fallbackAction]
            }

            actionItems = normalizedActionItems

            let modelClassification = normalizedClassification(output.classification)
            classification = ["todo", "both"].contains(modelClassification) ? modelClassification : "todo"
        } else {
            actionItems = []
            classification = "notebook"
        }

        return ThoughtProcessingOutput(
            title: output.title,
            distilled: output.distilled,
            classification: classification,
            tags: output.tags,
            pageId: normalizedPageID(output.pageId),
            pageParentId: normalizedPageParentID(pageID: output.pageId, parentID: output.pageParentId),
            pageTitle: output.pageTitle,
            pageSummary: output.pageSummary,
            pageBodyMarkdown: output.pageBodyMarkdown,
            themeTitle: output.themeTitle,
            themeSummary: output.themeSummary,
            linkedThoughtIds: normalizedLinkedThoughtIDs(output.linkedThoughtIds),
            dailyDigestTitle: output.dailyDigestTitle,
            dailyDigestSummary: output.dailyDigestSummary,
            dailyDigestHighlights: output.dailyDigestHighlights,
            actionItems: actionItems
        )
    }

    private func fallbackActionItem(
        for rawThought: String,
        inferredDueDate: Date?,
        inferredDueTime: String?
    ) -> ThoughtProcessingOutput.Action? {
        let title = actionTitle(from: rawThought)
        guard !title.isEmpty else {
            return nil
        }

        return ThoughtProcessingOutput.Action(
            title: title,
            detail: "",
            dueDate: formattedActionDate(inferredDueDate),
            dueTime: inferredDueTime ?? ""
        )
    }

    private func actionTitle(from rawThought: String) -> String {
        var title = rawThought.trimmingCharacters(in: .whitespacesAndNewlines)
        let removalPatterns = [
            #"\s+\b(at|by|before)\s+\d{1,2}(:\d{2})?\s?(am|pm)\b"#,
            #"\s+\b(at|by|before)\s+\d{1,2}(:\d{2})\b"#,
            #"\s+\b(today|tomorrow|tonight|this afternoon|this evening)\b"#,
            #"\s+\bby\s+(eod|end of day)\b"#
        ]

        for pattern in removalPatterns {
            title = title.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = title.first else {
            return ""
        }

        return first.uppercased() + title.dropFirst()
    }

    private func inferredDueDate(from rawThought: String) -> Date? {
        let lowercasedThought = rawThought.lowercased()
        guard hasDueDateSignal(in: lowercasedThought) || inferredTimeComponents(from: lowercasedThought) != nil else {
            return nil
        }

        var calendar = Calendar.current
        calendar.timeZone = .current

        var baseDate = Date()
        if lowercasedThought.contains("tomorrow"),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: baseDate) {
            baseDate = tomorrow
        } else if lowercasedThought.contains("next week"),
                  let nextWeek = calendar.date(byAdding: .day, value: 7, to: baseDate) {
            baseDate = nextWeek
        } else if let weekday = weekdayNumber(in: lowercasedThought),
                  let nextWeekday = nextDate(forWeekday: weekday, calendar: calendar, from: baseDate) {
            baseDate = nextWeekday
        }

        return calendar.startOfDay(for: baseDate)
    }

    private func inferredDueTime(from rawThought: String) -> String? {
        guard let time = inferredTimeComponents(from: rawThought.lowercased()) else {
            return nil
        }

        return String(format: "%02d:%02d", time.hour, time.minute)
    }

    private func formattedActionDate(_ date: Date?) -> String {
        date.map { Self.actionDate.string(from: $0) } ?? ""
    }

    private func hasDueDateSignal(in text: String) -> Bool {
        containsAny(
            text,
            [
                "today", "tomorrow", "tonight", "this afternoon", "this evening",
                "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                "next week", "by ", "before ", "due", "deadline"
            ]
        ) || text.range(of: #"\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}/\d{1,2}\b"#, options: .regularExpression) != nil
    }

    private func weekdayNumber(in text: String) -> Int? {
        let weekdays = [
            "sunday": 1,
            "monday": 2,
            "tuesday": 3,
            "wednesday": 4,
            "thursday": 5,
            "friday": 6,
            "saturday": 7
        ]
        return weekdays.first { text.contains($0.key) }?.value
    }

    private func nextDate(forWeekday weekday: Int, calendar: Calendar, from date: Date) -> Date? {
        let currentWeekday = calendar.component(.weekday, from: date)
        let daysAhead = (weekday - currentWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysAhead == 0 ? 7 : daysAhead, to: date)
    }

    private func inferredTimeComponents(from text: String) -> (hour: Int, minute: Int)? {
        if text.contains("eod") || text.contains("end of day") {
            return (17, 0)
        }

        if text.contains("noon") {
            return (12, 0)
        }

        if text.contains("midnight") {
            return (0, 0)
        }

        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b|\b(\d{1,2}):(\d{2})\b|\b(at|by|before)\s+(\d{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }

        func matchedString(at index: Int) -> String? {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound, let range = Range(matchRange, in: text) else {
                return nil
            }
            return String(text[range])
        }

        if let hourString = matchedString(at: 1), var hour = Int(hourString) {
            let minute = matchedString(at: 2).flatMap(Int.init) ?? 0
            let meridiem = matchedString(at: 3) ?? ""
            if meridiem == "pm", hour < 12 {
                hour += 12
            } else if meridiem == "am", hour == 12 {
                hour = 0
            }
            return (hour, minute)
        }

        if let hourString = matchedString(at: 4),
           let hour = Int(hourString),
           let minuteString = matchedString(at: 5),
           let minute = Int(minuteString) {
            return (hour, minute)
        }

        if let hourString = matchedString(at: 7), var hour = Int(hourString) {
            if (1...7).contains(hour) {
                hour += 12
            }
            return (hour, 0)
        }

        return nil
    }

    private func rawThoughtText(from prompt: String) -> String {
        let lines = prompt.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("raw:") {
                return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
        }
        return prompt
    }

    private func forcedTodoDirective(from prompt: String) -> Bool {
        let lines = prompt.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("todoDirective:")
                && trimmed.localizedCaseInsensitiveContains("forced")
        }
    }

    private func normalizedForcedTodoTitle(_ title: String, fallback: String) -> String {
        let cleanedTitle = clean(title)
        guard !cleanedTitle.isEmpty else {
            return clean(fallback)
        }

        guard ThoughtPrefixParser.todoHint(in: cleanedTitle) != nil else {
            return cleanedTitle
        }

        let strippedTitle = ThoughtPrefixParser.todoBody(in: cleanedTitle)
        return clean(strippedTitle).isEmpty ? clean(fallback) : clean(strippedTitle)
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedClassification(_ classification: String) -> String {
        let normalized = classification.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["todo", "notebook", "both"].contains(normalized) ? normalized : "notebook"
    }

    private static let actionDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private func map(_ error: Error) -> Error {
        guard let generationError = error as? LanguageModelSession.GenerationError else {
            return ThoughtAIProviderError.generationFailed(error.localizedDescription)
        }

        switch generationError {
        case .guardrailViolation:
            return ThoughtAIProviderError.blockedBySafety
        case .unsupportedLanguageOrLocale:
            return ThoughtAIProviderError.unsupportedLanguageOrLocale(Self.currentLanguageDescription)
        case .exceededContextWindowSize:
            return ThoughtAIProviderError.contextTooLarge
        case .rateLimited:
            return ThoughtAIProviderError.rateLimited
        case .assetsUnavailable:
            return ThoughtAIProviderError.unavailable("Apple Foundation Models assets are unavailable. The local model may still be downloading or preparing.")
        case .decodingFailure:
            return ThoughtAIProviderError.generationFailed("The model returned output that did not match the requested structured type.")
        case .unsupportedGuide:
            return ThoughtAIProviderError.generationFailed("The requested structured output guide is not supported by Foundation Models.")
        case .concurrentRequests:
            return ThoughtAIProviderError.generationFailed("A local generation request is already running for this session.")
        case .refusal:
            return ThoughtAIProviderError.blockedBySafety
        @unknown default:
            return ThoughtAIProviderError.generationFailed(error.localizedDescription)
        }
    }

    private func isUnsupportedLanguageOrLocale(_ error: Error) -> Bool {
        if case ThoughtAIProviderError.unsupportedLanguageOrLocale = error {
            return true
        }

        return false
    }

    private static var currentLanguageDescription: String {
        let languageCode = Locale.current.language.languageCode?.identifier ?? Locale.current.identifier
        let languageName = Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
        return "\(languageName) (\(languageCode))"
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationThoughtProcessingOutput {
    @Guide(description: "Short human-readable title for the thought.")
    var title: String
    @Guide(description: "Cleaned-up thought preserving the original meaning.")
    var distilled: String
    @Guide(description: "One of todo, notebook, or both.")
    var classification: String
    @Guide(description: "Concise lowercase tags.")
    var tags: [String]
    @Guide(description: "Existing page UUID if the thought belongs to one, otherwise empty.")
    var pageId: String
    @Guide(description: "Existing parent page UUID for a new page, otherwise empty.")
    var pageParentId: String
    @Guide(description: "Best matching page title, existing or new.")
    var pageTitle: String
    @Guide(description: "Updated concise summary for the page.")
    var pageSummary: String
    @Guide(description: "Concise markdown body for the page.")
    var pageBodyMarkdown: String
    @Guide(description: "Compatibility title matching pageTitle.")
    var themeTitle: String
    @Guide(description: "Compatibility summary matching pageSummary.")
    var themeSummary: String
    @Guide(description: "Related thought UUID strings from the prompt context only.")
    var linkedThoughtIds: [String]
    @Guide(description: "Short daily digest title.")
    var dailyDigestTitle: String
    @Guide(description: "Short daily digest summary.")
    var dailyDigestSummary: String
    @Guide(description: "Short daily digest highlights.")
    var dailyDigestHighlights: [String]
    @Guide(description: "Action items only for concrete tasks.")
    var actionItems: [FoundationActionItem]

    var output: ThoughtProcessingOutput {
        ThoughtProcessingOutput(
            title: title,
            distilled: distilled,
            classification: classification,
            tags: tags,
            pageId: pageId,
            pageParentId: pageParentId,
            pageTitle: pageTitle,
            pageSummary: pageSummary,
            pageBodyMarkdown: pageBodyMarkdown,
            themeTitle: themeTitle,
            themeSummary: themeSummary,
            linkedThoughtIds: linkedThoughtIds,
            dailyDigestTitle: dailyDigestTitle,
            dailyDigestSummary: dailyDigestSummary,
            dailyDigestHighlights: dailyDigestHighlights,
            actionItems: actionItems.map(\.output)
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationActionItem {
    @Guide(description: "Short imperative title.")
    var title: String
    @Guide(description: "Short detail, or empty.")
    var detail: String
    @Guide(description: "YYYY-MM-DD date if inferable, otherwise empty.")
    var dueDate: String
    @Guide(description: "24-hour HH:mm time if explicitly provided, otherwise empty.")
    var dueTime: String

    var output: ThoughtProcessingOutput.Action {
        ThoughtProcessingOutput.Action(title: title, detail: detail, dueDate: dueDate, dueTime: dueTime)
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationThoughtSynthesisOutput {
    @Guide(description: "Concise valid markdown page synthesis.")
    var synthesisMarkdown: String
}

@available(macOS 26.0, *)
@Generable
private struct FoundationReorganizationOutput {
    @Guide(description: "Brief notes explaining meaningful grouping changes.")
    var notes: [String]
    @Guide(description: "Existing page UUIDs that should be deleted.")
    var deletedPageIds: [String]
    @Guide(description: "Complete proposed page tree.")
    var pages: [FoundationProposedThoughtPage]

    var proposal: ReorganizationProposal {
        ReorganizationProposal(
            notes: notes,
            deletedPageIDs: deletedPageIds.compactMap(UUID.init(uuidString:)),
            pages: pages.map(\.proposal)
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationProposedThoughtPage {
    @Guide(description: "Existing page UUID or stable temporary id.")
    var id: String
    @Guide(description: "Existing page UUID if retaining or changing it, otherwise empty.")
    var existingPageId: String
    @Guide(description: "Parent proposed id or existing UUID, empty for top-level.")
    var parentId: String
    @Guide(description: "Page title.")
    var title: String
    @Guide(description: "Concise page summary.")
    var summary: String
    @Guide(description: "Useful markdown page body.")
    var bodyMarkdown: String
    @Guide(description: "Concise lowercase tags.")
    var tags: [String]
    @Guide(description: "Thought UUID strings assigned to this page.")
    var thoughtIds: [String]

    var proposal: ProposedThoughtPage {
        ProposedThoughtPage(
            id: id,
            existingPageID: UUID(uuidString: existingPageId),
            parentID: parentId.isEmpty ? nil : parentId,
            title: title,
            summary: summary,
            bodyMarkdown: bodyMarkdown,
            tags: tags,
            thoughtIDs: thoughtIds.compactMap(UUID.init(uuidString:))
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct FoundationTagSuggestions {
    @Guide(description: "Concise lowercase tags.")
    var tags: [String]
}

@available(macOS 26.0, *)
private struct NotebookSearchTool: Tool {
    let name = "searchNotebookContext"
    let description = "Search local Sift pages and thoughts by query. Read-only."
    let store: ThoughtStore

    @Generable
    struct Arguments {
        @Guide(description: "Search query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else {
                return "No query provided."
            }

            let thoughtMatches = store.thoughts
                .filter { thought in
                    [thought.text, thought.title ?? "", thought.distilled ?? "", thought.tags.joined(separator: " ")]
                        .joined(separator: " ")
                        .lowercased()
                        .contains(query)
                }
                .prefix(8)
                .map { thought in
                    "- thought id: \(thought.id.uuidString), title: \(thought.title ?? ""), raw: \(thought.text)"
                }

            let pageMatches = store.pages
                .filter { page in
                    [page.title, page.summary, page.bodyMarkdown, page.tags.joined(separator: " ")]
                        .joined(separator: " ")
                        .lowercased()
                        .contains(query)
                }
                .prefix(8)
                .map { page in
                    "- page id: \(page.id.uuidString), title: \(page.title), summary: \(page.summary)"
                }

            let combined = (["Thought matches:"] + thoughtMatches + ["Page matches:"] + pageMatches)
                .joined(separator: "\n")
            return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No matches." : combined
        }
    }
}

@available(macOS 26.0, *)
private struct PageContextTool: Tool {
    let name = "getPageContext"
    let description = "Fetch a local Sift page and its linked thoughts by page UUID. Read-only."
    let store: ThoughtStore

    @Generable
    struct Arguments {
        @Guide(description: "Page UUID.")
        var pageId: String
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let id = UUID(uuidString: arguments.pageId),
                  let page = store.page(with: id) else {
                return "Page not found."
            }

            let thoughts = page.thoughtIDs
                .compactMap(store.thought(with:))
                .prefix(20)
                .map { thought in
                    "- thought id: \(thought.id.uuidString), title: \(thought.title ?? ""), raw: \(thought.text), distilled: \(thought.distilled ?? "")"
                }
                .joined(separator: "\n")

            return """
            page id: \(page.id.uuidString)
            title: \(page.title)
            summary: \(page.summary)
            bodyMarkdown:
            \(page.bodyMarkdown)

            linkedThoughts:
            \(thoughts.isEmpty ? "None" : thoughts)
            """
        }
    }
}
#endif
