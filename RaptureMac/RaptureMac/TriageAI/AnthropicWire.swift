import Foundation

/// Pure request builder + response parser for the Anthropic Messages API —
/// everything about the BYO-key engine that can be golden-tested with zero
/// network. `AnthropicEngine` owns the URLSession call; this owns the bytes.
enum AnthropicWire {
    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    nonisolated static let apiVersion = "2023-06-01"
    /// The model when a caller doesn't name one (Settings → Triage picks it).
    nonisolated static let defaultModel = ClaudeModel.sonnet55
    /// Server-side refusal fallback, `"default"` form (Sonnet 5.5, Claude API).
    nonisolated static let fallbackBeta = "server-side-fallback-2026-07-01"

    // MARK: - Request

    nonisolated static func makeRequest(
        apiKey: String,
        text: String,
        capturedAt: Date,
        timeZone: TimeZone,
        model: ClaudeModel = defaultModel
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = model.timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if model.usesServerFallback {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: requestBody(text: text, capturedAt: capturedAt, timeZone: timeZone, model: model),
            options: [.sortedKeys]
        )
        return request
    }

    /// No `thinking` field: Sonnet 5.5 runs adaptive thinking by default and
    /// `low` effort keeps it short (its `disabled` value is a 400). No
    /// sampling parameters and no assistant prefill: Sonnet 5.5 rejects both.
    /// The response is read by block type, so a leading `thinking` block (or a
    /// `fallback` marker) is skipped.
    nonisolated static func requestBody(
        text: String,
        capturedAt: Date,
        timeZone: TimeZone,
        model: ClaudeModel = defaultModel
    ) -> [String: Any] {
        var outputConfig: [String: Any] = [
            "format": [
                "type": "json_schema",
                "schema": draftSchema
            ]
        ]
        if let effort = model.effort {
            outputConfig["effort"] = effort
        }
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": model.maxTokens,
            "system": AITriagePrompt.instructions,
            "messages": [
                [
                    "role": "user",
                    "content": AITriagePrompt.userMessage(text: text, capturedAt: capturedAt, timeZone: timeZone)
                ]
            ],
            "output_config": outputConfig
        ]
        if model.usesServerFallback {
            body["fallbacks"] = "default"
        }
        return body
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
