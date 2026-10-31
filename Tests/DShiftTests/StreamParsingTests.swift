import Testing

@testable import DShift

struct StreamParsingTests {
    @Test func claudeParsesContentBlockEvents() throws {
        let start = try ClaudeClient.parseEvents(
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text"}}"#)
        guard case .blockStart(let index, let block) = start.first else {
            Issue.record("expected blockStart")
            return
        }
        #expect(index == 2)
        #expect(block["type"] as? String == "text")

        let delta = try ClaudeClient.parseEvents(
            #"data: {"type":"content_block_delta","index":1,"delta":{"text":"hi"}}"#)
        guard case .blockDelta(1, let fields) = delta.first else {
            Issue.record("expected blockDelta")
            return
        }
        #expect(fields["text"] as? String == "hi")

        let stop = try ClaudeClient.parseEvents(#"data: {"type":"content_block_stop","index":3}"#)
        guard case .blockStop(3) = stop.first else {
            Issue.record("expected blockStop")
            return
        }
    }

    @Test func claudeReadsUsageAndStopReason() throws {
        let start = try ClaudeClient.parseEvents(
            #"data: {"type":"message_start","message":{"usage":{"input_tokens":5}}}"#)
        guard case .usage(let usage) = start.first else {
            Issue.record("expected usage")
            return
        }
        #expect(usage["input_tokens"] as? Int == 5)

        let end = try ClaudeClient.parseEvents(
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#)
        #expect(end.count == 2)
        guard case .stopReason("tool_use") = end.first, case .usage = end.last else {
            Issue.record("wrong order")
            return
        }
    }

    @Test func claudeIgnoresNonDataLinesAndThrowsOnErrors() throws {
        #expect(try ClaudeClient.parseEvents("event: ping").isEmpty)
        #expect(try ClaudeClient.parseEvents(#"data: {"type":"ping"}"#).isEmpty)
        #expect(throws: ClaudeError.self) {
            try ClaudeClient.parseEvents(#"data: {"type":"error","error":{"message":"overloaded"}}"#)
        }
        #expect(throws: (any Error).self) { try ClaudeClient.parseEvents("data: {not json") }
    }

    @Test func openAIParsesTextAndUsage() throws {
        guard
            case .text("abc") = try OpenAIClient.parseEvent(
                #"data: {"type":"response.output_text.delta","delta":"abc"}"#)
        else {
            Issue.record("expected text")
            return
        }
        let done = try OpenAIClient.parseEvent(
            #"data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":4}}}"#)
        guard case .usage(3, 4) = done else {
            Issue.record("expected usage")
            return
        }
    }

    @Test func openAIIgnoresNoiseAndThrowsOnFailure() throws {
        #expect(try OpenAIClient.parseEvent("event: x") == nil)
        #expect(try OpenAIClient.parseEvent("data: {not json") == nil)
        #expect(try OpenAIClient.parseEvent(#"data: {"type":"response.created"}"#) == nil)
        #expect(throws: ToolError.self) {
            try OpenAIClient.parseEvent(#"data: {"type":"response.failed","response":{}}"#)
        }
        #expect(throws: ToolError.self) { try OpenAIClient.parseEvent(#"data: {"type":"error","message":"x"}"#) }
    }
}
