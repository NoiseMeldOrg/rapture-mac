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
        XCTAssertEqual(request.timeoutInterval, AnthropicWire.requestTimeout)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(json["max_tokens"] as? Int, AnthropicWire.maxTokens)
        XCTAssertEqual(json["system"] as? String, AITriagePrompt.instructions)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("buy milk") == true)

        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
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
