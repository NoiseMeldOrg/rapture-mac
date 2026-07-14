import Foundation

/// Pure request builder + response parser for the Anthropic Messages API —
/// everything about the BYO-key engine that can be golden-tested with zero
/// network. `AnthropicEngine` owns the URLSession call; this owns the bytes.
enum AnthropicWire {
    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    nonisolated static let apiVersion = "2023-06-01"
    /// Short-note classification is a small-cheap-model task (locked decision).
    nonisolated static let model = "claude-haiku-4-5"
    nonisolated static let maxTokens = 2048
    nonisolated static let requestTimeout: TimeInterval = 10

    // MARK: - Request

    nonisolated static func makeRequest(
        apiKey: String,
        text: String,
        capturedAt: Date,
        timeZone: TimeZone
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: requestBody(text: text, capturedAt: capturedAt, timeZone: timeZone),
            options: [.sortedKeys]
        )
        return request
    }

    nonisolated static func requestBody(text: String, capturedAt: Date, timeZone: TimeZone) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": AITriagePrompt.instructions,
            "messages": [
                [
                    "role": "user",
                    "content": AITriagePrompt.userMessage(text: text, capturedAt: capturedAt, timeZone: timeZone)
                ]
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": draftSchema
                ]
            ]
        ]
    }

    /// JSON schema mirroring `AIEngineDraft` — structured outputs guarantee the
    /// first text block is valid JSON matching this shape.
    nonisolated static var draftSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["classification", "title", "formattedBody", "handoffs"],
            "properties": [
                "classification": [
                    "type": ["string", "null"],
                    "enum": ["task", "idea", "journal", NSNull()]
                ],
                "title": ["type": ["string", "null"]],
                "formattedBody": ["type": ["string", "null"]],
                "handoffs": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["kind", "title", "clause", "year", "month", "day", "hour", "minute"],
                        "properties": [
                            "kind": ["type": "string", "enum": ["reminder", "event"]],
                            "title": ["type": "string"],
                            "clause": ["type": "string"],
                            "year": ["type": ["integer", "null"]],
                            "month": ["type": ["integer", "null"]],
                            "day": ["type": ["integer", "null"]],
                            "hour": ["type": ["integer", "null"]],
                            "minute": ["type": ["integer", "null"]]
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Response

    private struct MessagesResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        let content: [ContentBlock]
        let stop_reason: String?
    }

    /// Non-200 → `.http(status)` (401 gets the key-rejected latch upstream);
    /// `refusal` / `max_tokens` stop reasons and undecodable payloads all map to
    /// typed errors — every one of them means "file deterministically".
    nonisolated static func parseResponse(data: Data, statusCode: Int) throws -> AIEngineDraft {
        guard statusCode == 200 else { throw AIEngineError.http(statusCode) }
        guard let response = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw AIEngineError.invalidOutput
        }
        switch response.stop_reason {
        case "refusal":
            throw AIEngineError.refusal
        case "max_tokens":
            throw AIEngineError.truncated
        default:
            break
        }
        guard let text = response.content.first(where: { $0.type == "text" })?.text,
              let draft = try? JSONDecoder().decode(AIEngineDraft.self, from: Data(text.utf8)) else {
            throw AIEngineError.invalidOutput
        }
        return draft
    }
}
