import Foundation

struct ThoughtProcessingOutput: Decodable {
    struct Action: Decodable {
        let title: String
        let detail: String
        let dueAt: String
    }

    let title: String
    let distilled: String
    let tags: [String]
    let themeTitle: String
    let themeSummary: String
    let linkedThoughtIds: [String]
    let dailyDigestTitle: String
    let dailyDigestSummary: String
    let dailyDigestHighlights: [String]
    let actionItems: [Action]
}

enum OpenAIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case apiError(String)
    case missingOutputText

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Invalid OpenAI proxy URL."
        case .invalidResponse:
            "OpenAI returned an invalid response."
        case .apiError(let message):
            message
        case .missingOutputText:
            "OpenAI response did not include structured output text."
        }
    }
}

struct OpenAIClient {
    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func process(input: ThoughtProcessingInput) async throws -> ThoughtProcessingOutput {
        let payload = try makePayload(input: input)
        var request = authenticatedRequest(url: try endpointURL(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAIClientError.apiError(apiErrorMessage(from: data) ?? "OpenAI request failed with status \(httpResponse.statusCode).")
        }

        let outputText = try outputText(from: data)
        return try JSONDecoder().decode(ThoughtProcessingOutput.self, from: Data(outputText.utf8))
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

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func makePayload(input: ThoughtProcessingInput) throws -> [String: Any] {
        [
            "model": settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            "input": [
                [
                    "role": "system",
                    "content": """
                    You organize a private thought-capture notebook. Keep raw meaning intact, derive concise metadata, and only create action items for explicit or strongly implied actions. Return JSON that exactly matches the schema.
                    """
                ],
                [
                    "role": "user",
                    "content": input.prompt
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "thought_distillation",
                    "strict": true,
                    "schema": Self.schema
                ]
            ]
        ]
    }

    private func outputText(from data: Data) throws -> String {
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

    private func apiErrorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message
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

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "title",
            "distilled",
            "tags",
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
            "tags": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "themeTitle": [
                "type": "string",
                "description": "Best matching rolling theme title, existing or new."
            ],
            "themeSummary": [
                "type": "string",
                "description": "Updated summary for the theme."
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
                            "description": "ISO-8601 date if explicitly inferable, otherwise empty string."
                        ]
                    ]
                ]
            ]
        ]
    ]
}
