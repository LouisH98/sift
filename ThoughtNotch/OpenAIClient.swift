import Foundation

struct ThoughtProcessingOutput: Decodable {
    struct Action: Decodable {
        let title: String
        let detail: String
        let dueAt: String
    }

    let title: String
    let distilled: String
    let classification: String
    let tags: [String]
    let pageId: String
    let pageParentId: String
    let pageTitle: String
    let pageSummary: String
    let pageBodyMarkdown: String
    let themeTitle: String
    let themeSummary: String
    let linkedThoughtIds: [String]
    let dailyDigestTitle: String
    let dailyDigestSummary: String
    let dailyDigestHighlights: [String]
    let actionItems: [Action]
}

struct ThoughtSynthesisOutput: Decodable {
    let synthesisMarkdown: String
}

enum OpenAIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case apiError(String)
    case missingOutputText

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Invalid AI provider base URL."
        case .invalidResponse:
            "AI provider returned an invalid response."
        case .apiError(let message):
            message
        case .missingOutputText:
            "AI provider response did not include structured output text."
        }
    }
}

@MainActor
struct OpenAIClient {
    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func process(input: ThoughtProcessingInput) async throws -> ThoughtProcessingOutput {
        let outputText = try await requestOutputText(
            systemPrompt: """
            You organize a private thought-capture notebook. Keep raw meaning intact, route thoughts into a hierarchical page tree, and only create action items for explicit or strongly implied actions. Return JSON that exactly matches the schema.
            """,
            userPrompt: input.prompt,
            schemaName: "thought_distillation",
            schema: Self.processingSchema,
            exampleJSON: Self.processingExampleJSON,
            timeout: 120,
            maxTokens: 4096,
            failureMessage: "AI request failed"
        )
        return try JSONDecoder().decode(ThoughtProcessingOutput.self, from: Data(outputText.utf8))
    }

    func reorganize(input: ThoughtReorganizationInput) async throws -> ReorganizationProposal {
        let outputText = try await requestOutputText(
            systemPrompt: """
            You reorganize a private thought notebook. Preserve every raw thought ID, propose a clear hierarchical page tree, and produce concise Notion-style page summaries and body markdown. Return JSON that exactly matches the schema.
            """,
            userPrompt: input.prompt,
            schemaName: "thought_reorganization",
            schema: Self.reorganizationSchema,
            exampleJSON: Self.reorganizationExampleJSON,
            timeout: 90,
            maxTokens: 12000,
            failureMessage: "AI reorganization request failed"
        )
        let output = try JSONDecoder().decode(ReorganizationClientOutput.self, from: Data(outputText.utf8))
        return output.proposal
    }

    func synthesizePage(input: ThoughtSynthesisInput) async throws -> ThoughtSynthesisOutput {
        let outputText = try await requestOutputText(
            systemPrompt: """
            You synthesize a private notebook page. Write concise, valid markdown with clear block structure and blank lines between headings, paragraphs, and lists. Surface patterns, tensions, open loops, decisions, and emerging structure without becoming wordy. Return JSON that exactly matches the schema.
            """,
            userPrompt: input.prompt,
            schemaName: "thought_page_synthesis",
            schema: Self.synthesisSchema,
            exampleJSON: Self.synthesisExampleJSON,
            timeout: 90,
            maxTokens: 2048,
            failureMessage: "AI synthesis request failed"
        )
        return try JSONDecoder().decode(ThoughtSynthesisOutput.self, from: Data(outputText.utf8))
    }

    func availableModels() async throws -> [String] {
        var request = authenticatedRequest(url: try endpointURL(path: "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAIClientError.apiError(apiErrorMessage(from: data) ?? "Model list request failed with status \(httpResponse.statusCode).")
        }

        return try JSONDecoder().decode(ModelsEnvelope.self, from: data)
            .data
            .map(\.id)
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                let lhsIsGPT = lhs.localizedCaseInsensitiveContains("gpt")
                let rhsIsGPT = rhs.localizedCaseInsensitiveContains("gpt")

                if lhsIsGPT != rhsIsGPT {
                    return lhsIsGPT
                }

                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private func requestOutputText(
        systemPrompt: String,
        userPrompt: String,
        schemaName: String,
        schema: [String: Any],
        exampleJSON: String,
        timeout: TimeInterval,
        maxTokens: Int,
        failureMessage: String
    ) async throws -> String {
        let endpointPath: String
        let payload: [String: Any]

        switch settings.apiEndpoint {
        case .responses:
            endpointPath = "responses"
            payload = responsesPayload(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                schemaName: schemaName,
                schema: schema
            )
        case .chatCompletions:
            endpointPath = "chat/completions"
            payload = chatCompletionsPayload(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                exampleJSON: exampleJSON,
                maxTokens: maxTokens
            )
        }

        let data = try await executeJSONRequest(
            endpointPath: endpointPath,
            payload: payload,
            timeout: timeout,
            failureMessage: failureMessage
        )

        switch settings.apiEndpoint {
        case .responses:
            return try responsesOutputText(from: data)
        case .chatCompletions:
            return try chatCompletionOutputText(from: data)
        }
    }

    private func executeJSONRequest(
        endpointPath: String,
        payload: [String: Any],
        timeout: TimeInterval,
        failureMessage: String
    ) async throws -> Data {
        var request = authenticatedRequest(url: try endpointURL(path: endpointPath))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAIClientError.apiError(apiFailureMessage(
                from: data,
                statusCode: httpResponse.statusCode,
                failureMessage: failureMessage
            ))
        }

        return data
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let apiKey = settings.loadAPIKeyIfNeeded().trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func endpointURL(path endpointPath: String) throws -> URL {
        let rawBaseURL = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: rawBaseURL), components.scheme != nil, components.host != nil else {
            throw OpenAIClientError.invalidBaseURL
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/\(endpointPath)" : "/\(path)/\(endpointPath)"

        guard let url = components.url else {
            throw OpenAIClientError.invalidBaseURL
        }

        return url
    }

    private func responsesPayload(
        systemPrompt: String,
        userPrompt: String,
        schemaName: String,
        schema: [String: Any]
    ) -> [String: Any] {
        [
            "model": settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "input": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userPrompt
                ]
            ],
            "text": [
                "format": jsonSchemaFormat(name: schemaName, schema: schema)
            ]
        ]
    }

    private func chatCompletionsPayload(
        systemPrompt: String,
        userPrompt: String,
        exampleJSON: String,
        maxTokens: Int
    ) -> [String: Any] {
        [
            "model": settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                [
                    "role": "system",
                    "content": chatJSONSystemPrompt(systemPrompt: systemPrompt, exampleJSON: exampleJSON)
                ],
                [
                    "role": "user",
                    "content": userPrompt
                ]
            ],
            "response_format": [
                "type": "json_object"
            ],
            "max_tokens": maxTokens
        ]
    }

    private func jsonSchemaFormat(name: String, schema: [String: Any]) -> [String: Any] {
        [
            "type": "json_schema",
            "name": name,
            "strict": true,
            "schema": schema
        ]
    }

    private func chatJSONSystemPrompt(systemPrompt: String, exampleJSON: String) -> String {
        """
        \(systemPrompt)

        JSON OUTPUT REQUIREMENTS:
        - Return only one valid JSON object.
        - Do not include markdown fences, prose, comments, or any text outside the JSON object.
        - Include every key shown in the example JSON output.
        - Use empty strings or empty arrays when there is no value.

        EXAMPLE JSON OUTPUT:
        \(exampleJSON)
        """
    }

    private func responsesOutputText(from data: Data) throws -> String {
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
        if let outputText = envelope.outputText, !outputText.isEmpty {
            return outputText
        }

        let text = envelope.output
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined()

        guard !text.isEmpty else {
            throw OpenAIClientError.missingOutputText
        }

        return text
    }

    private func chatCompletionOutputText(from data: Data) throws -> String {
        let envelope = try JSONDecoder().decode(ChatCompletionEnvelope.self, from: data)
        let text = envelope.choices
            .compactMap(\.message.content)
            .joined()

        guard !text.isEmpty else {
            throw OpenAIClientError.missingOutputText
        }

        return text
    }

    private func apiErrorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message
    }

    private func apiFailureMessage(from data: Data, statusCode: Int, failureMessage: String) -> String {
        if let message = apiErrorMessage(from: data) {
            return message
        }

        if statusCode == 404 {
            switch settings.apiEndpoint {
            case .responses:
                return "\(failureMessage) with status 404. This provider may not support the Responses API; try API type \"Chat Completions\"."
            case .chatCompletions:
                return "\(failureMessage) with status 404. Check that the base URL includes the provider API prefix, such as /v1."
            }
        }

        return "\(failureMessage) with status \(statusCode)."
    }

    private struct ResponseEnvelope: Decodable {
        let output: [Output]
        let outputText: String?

        enum CodingKeys: String, CodingKey {
            case output
            case outputText = "output_text"
        }
    }

    private struct Output: Decodable {
        let content: [Content]?
    }

    private struct Content: Decodable {
        let text: String?
    }

    private struct ChatCompletionEnvelope: Decodable {
        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: String?
        }

        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

    private struct ModelsEnvelope: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    private struct ReorganizationClientOutput: Decodable {
        struct Page: Decodable {
            let id: String
            let existingPageId: String
            let parentId: String
            let title: String
            let summary: String
            let bodyMarkdown: String
            let tags: [String]
            let thoughtIds: [String]
        }

        let notes: [String]
        let deletedPageIds: [String]
        let pages: [Page]

        var proposal: ReorganizationProposal {
            ReorganizationProposal(
                notes: notes,
                deletedPageIDs: deletedPageIds.compactMap(UUID.init(uuidString:)),
                pages: pages.map { page in
                    ProposedThoughtPage(
                        id: page.id,
                        existingPageID: UUID(uuidString: page.existingPageId),
                        parentID: page.parentId.isEmpty ? nil : page.parentId,
                        title: page.title,
                        summary: page.summary,
                        bodyMarkdown: page.bodyMarkdown,
                        tags: page.tags,
                        thoughtIDs: page.thoughtIds.compactMap(UUID.init(uuidString:))
                    )
                }
            )
        }
    }

    private static let processingExampleJSON = """
    {
      "title": "Follow up on launch plan",
      "distilled": "Follow up with Sam about the launch plan before Friday.",
      "classification": "both",
      "tags": ["launch", "follow-up"],
      "pageId": "",
      "pageParentId": "",
      "pageTitle": "Launch Planning",
      "pageSummary": "Current decisions, open loops, and follow-ups for launch planning.",
      "pageBodyMarkdown": "## Notes\\n\\nFollow up with Sam about the launch plan before Friday.",
      "themeTitle": "Launch Planning",
      "themeSummary": "Current decisions, open loops, and follow-ups for launch planning.",
      "linkedThoughtIds": [],
      "dailyDigestTitle": "Launch follow-ups",
      "dailyDigestSummary": "Captured a follow-up related to the launch plan.",
      "dailyDigestHighlights": ["Follow up with Sam about the launch plan."],
      "actionItems": [
        {
          "title": "Follow up with Sam",
          "detail": "Ask Sam about the launch plan.",
          "dueAt": "2026-05-01T17:00:00+01:00"
        }
      ]
    }
    """

    private static let reorganizationExampleJSON = """
    {
      "notes": ["Grouped related launch thoughts under one planning page."],
      "deletedPageIds": [],
      "pages": [
        {
          "id": "new-launch-planning",
          "existingPageId": "",
          "parentId": "",
          "title": "Launch Planning",
          "summary": "Decisions, open loops, and follow-ups for launch planning.",
          "bodyMarkdown": "## Current Shape\\n\\nKey launch notes and next decisions.",
          "tags": ["launch", "planning"],
          "thoughtIds": ["00000000-0000-0000-0000-000000000000"]
        }
      ]
    }
    """

    private static let synthesisExampleJSON = """
    {
      "synthesisMarkdown": "## Current Shape\\n\\nThe page is collecting launch planning decisions and follow-ups.\\n\\n## Open Loops\\n\\n- Confirm the next owner and timeline."
    }
    """

    private static let processingSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "title",
            "distilled",
            "classification",
            "tags",
            "pageId",
            "pageParentId",
            "pageTitle",
            "pageSummary",
            "pageBodyMarkdown",
            "themeTitle",
            "themeSummary",
            "linkedThoughtIds",
            "dailyDigestTitle",
            "dailyDigestSummary",
            "dailyDigestHighlights",
            "actionItems"
        ],
        "properties": [
            "title": [
                "type": "string",
                "description": "Short human-readable title for the thought."
            ],
            "distilled": [
                "type": "string",
                "description": "Cleaned-up version of the thought, preserving meaning."
            ],
            "classification": [
                "type": "string",
                "enum": ["todo", "notebook", "both"],
                "description": "Whether the thought is action-only, notebook-only, or both."
            ],
            "tags": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "pageId": [
                "type": "string",
                "description": "Existing page UUID if the thought belongs to one; empty string for a new page."
            ],
            "pageParentId": [
                "type": "string",
                "description": "Existing parent page UUID for a new or moved page; empty string for top level."
            ],
            "pageTitle": [
                "type": "string",
                "description": "Best matching page title, existing or new."
            ],
            "pageSummary": [
                "type": "string",
                "description": "Updated concise summary for the page."
            ],
            "pageBodyMarkdown": [
                "type": "string",
                "description": "Notion-style markdown body for the page, synthesized from linked raw thoughts."
            ],
            "themeTitle": [
                "type": "string",
                "description": "Compatibility field. Match pageTitle."
            ],
            "themeSummary": [
                "type": "string",
                "description": "Compatibility field. Match pageSummary."
            ],
            "linkedThoughtIds": [
                "type": "array",
                "items": ["type": "string"],
                "description": "UUID strings of related thoughts from the provided context only."
            ],
            "dailyDigestTitle": [
                "type": "string"
            ],
            "dailyDigestSummary": [
                "type": "string"
            ],
            "dailyDigestHighlights": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "actionItems": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "detail", "dueAt"],
                    "properties": [
                        "title": ["type": "string"],
                        "detail": ["type": "string"],
                        "dueAt": [
                            "type": "string",
                            "description": "ISO-8601 date-time with timezone if explicitly or strongly inferable from the thought and date context, otherwise empty string."
                        ]
                    ]
                ]
            ]
        ]
    ]

    private static let reorganizationSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["notes", "deletedPageIds", "pages"],
        "properties": [
            "notes": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "deletedPageIds": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Existing page UUIDs that should be deleted because they are replaced by the proposed structure."
            ],
            "pages": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "id",
                        "existingPageId",
                        "parentId",
                        "title",
                        "summary",
                        "bodyMarkdown",
                        "tags",
                        "thoughtIds"
                    ],
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Use an existing page UUID, or a stable temporary id like new-product-strategy."
                        ],
                        "existingPageId": [
                            "type": "string",
                            "description": "Existing page UUID when retaining/renaming a page; empty string for new pages."
                        ],
                        "parentId": [
                            "type": "string",
                            "description": "Parent proposed id or existing UUID; empty string for top-level pages."
                        ],
                        "title": ["type": "string"],
                        "summary": ["type": "string"],
                        "bodyMarkdown": ["type": "string"],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"]
                        ],
                        "thoughtIds": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ]
                ]
            ]
        ]
    ]

    private static let synthesisSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["synthesisMarkdown"],
        "properties": [
            "synthesisMarkdown": [
                "type": "string",
                "description": "The default markdown view for the page. Use concise markdown, 80-140 words by default, with blank lines between blocks and 2-4 short sections or bullet groups."
            ]
        ]
    ]
}
