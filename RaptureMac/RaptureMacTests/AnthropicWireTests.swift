import XCTest
@testable import Rapture

/// Golden tests for the pure Anthropic request builder + response parser —
/// zero network, ever.
final class AnthropicWireTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let zone = TimeZone(identifier: "America/New_York")!

    // MARK: - Request

    func testRequestShape() throws {
        let request = AnthropicWire.makeRequest(
            apiKey: "sk-test-123", text: "buy milk", capturedAt: capturedAt, timeZone: zone
        )
        XCTAssertEqual(request.url, AnthropicWire.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try body(of: request)
        XCTAssertEqual(json["system"] as? String, AITriagePrompt.instructions)
        XCTAssertNil(json["temperature"], "Sonnet 5.5 rejects non-default sampling")
        XCTAssertNil(json["thinking"], "adaptive by default; 'disabled' is a 400 on Sonnet 5.5")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "no assistant prefill")
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("buy milk") == true)

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
    }

    func testSonnetIsTheDefaultAtLowEffortWithServerFallback() throws {
        let request = AnthropicWire.makeRequest(
            apiKey: "k", text: "note", capturedAt: capturedAt, timeZone: zone
        )
        let json = try body(of: request)
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, ClaudeModel.sonnet55.maxTokens)
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(request.timeoutInterval, ClaudeModel.sonnet55.timeout)
    }

    func testHaikuSendsNoEffortAndNoFallback() throws {
        let request = AnthropicWire.makeRequest(
            apiKey: "k", text: "note", capturedAt: capturedAt, timeZone: zone, model: .haiku45
        )
        let json = try body(of: request)
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertNil((json["output_config"] as? [String: Any])?["effort"], "Haiku 4.5 rejects effort")
        XCTAssertNil(json["fallbacks"])
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testLeadingThinkingAndFallbackBlocksAreSkipped() throws {
        let payload: [String: Any] = [
            "content": [
                ["type": "fallback"],
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": goodDraftJSON]
            ],
            "stop_reason": "end_turn"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNoThrow(try AnthropicWire.parseResponse(data: data, statusCode: 200))
    }

    func testClaudePreferenceWinsOnlyWithAUsableKey() {
        XCTAssertEqual(AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil,
                                                hasAPIKey: true, keyRejected: false, preferClaude: true), .anthropic)
        XCTAssertEqual(AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil,
                                                hasAPIKey: true, keyRejected: false, preferClaude: false), .apple,
                       "Apple Intelligence stays first unless the user picks Claude")
        XCTAssertEqual(AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil,
                                                hasAPIKey: true, keyRejected: true, preferClaude: true), .apple,
                       "a rejected key falls back to on-device")
        XCTAssertEqual(AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil,
                                                hasAPIKey: false, keyRejected: false, preferClaude: true), .apple)
    }

    func testOlderSettingsKeepAppleFirstAndDefaultToSonnet() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"aiTriageEnabled": true}"#.utf8))
        XCTAssertEqual(settings.aiEnginePreference, .appleFirst, "no one's notes move to the cloud on update")
        XCTAssertEqual(settings.claudeModel, .sonnet55)
        let odd = try JSONDecoder().decode(Settings.self, from: Data(#"{"claudeModel": "claude-future-9"}"#.utf8))
        XCTAssertEqual(odd.claudeModel, .sonnet55, "an unknown model id degrades, never resets all settings")
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testKeyOnlyInHeaderNeverInBody() throws {
        let request = AnthropicWire.makeRequest(
            apiKey: "sk-secret-xyz", text: "note", capturedAt: capturedAt, timeZone: zone
        )
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("sk-secret-xyz"))
    }

    // MARK: - Response parsing

    private func responseData(stopReason: String = "end_turn", text: String) -> Data {
        let payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private let goodDraftJSON = """
    {"classification":"task","title":"Buy milk","formattedBody":null,
     "handoffs":[{"kind":"reminder","title":"Buy milk","clause":"remind me to buy milk",
                  "year":null,"month":null,"day":null,"hour":null,"minute":null}]}
    """

    func testParsesGoodResponse() throws {
        let draft = try AnthropicWire.parseResponse(
            data: responseData(text: goodDraftJSON), statusCode: 200
        )
        XCTAssertEqual(draft.classification, "task")
        XCTAssertEqual(draft.title, "Buy milk")
        XCTAssertNil(draft.formattedBody)
        XCTAssertEqual(draft.handoffs.count, 1)
        XCTAssertEqual(draft.handoffs.first?.kind, "reminder")
        XCTAssertEqual(draft.handoffs.first?.clause, "remind me to buy milk")
        XCTAssertNil(draft.handoffs.first?.year)
    }

    func testNon200ThrowsHTTP() {
        XCTAssertThrowsError(try AnthropicWire.parseResponse(data: Data(), statusCode: 401)) { error in
            XCTAssertEqual(error as? AIEngineError, .http(401))
        }
        XCTAssertThrowsError(try AnthropicWire.parseResponse(data: Data(), statusCode: 529)) { error in
            XCTAssertEqual(error as? AIEngineError, .http(529))
        }
    }

    func testRefusalStopReasonThrows() {
        XCTAssertThrowsError(
            try AnthropicWire.parseResponse(data: responseData(stopReason: "refusal", text: ""), statusCode: 200)
        ) { error in
            XCTAssertEqual(error as? AIEngineError, .refusal)
        }
    }

    func testMaxTokensStopReasonThrowsTruncated() {
        XCTAssertThrowsError(
            try AnthropicWire.parseResponse(
                data: responseData(stopReason: "max_tokens", text: goodDraftJSON), statusCode: 200
            )
        ) { error in
            XCTAssertEqual(error as? AIEngineError, .truncated)
        }
    }

    func testGarbageTextBlockThrowsInvalidOutput() {
        XCTAssertThrowsError(
            try AnthropicWire.parseResponse(data: responseData(text: "not json at all"), statusCode: 200)
        ) { error in
            XCTAssertEqual(error as? AIEngineError, .invalidOutput)
        }
    }

    func testUndecodableEnvelopeThrowsInvalidOutput() {
        XCTAssertThrowsError(
            try AnthropicWire.parseResponse(data: Data("<html>oops</html>".utf8), statusCode: 200)
        ) { error in
            XCTAssertEqual(error as? AIEngineError, .invalidOutput)
        }
    }
}
