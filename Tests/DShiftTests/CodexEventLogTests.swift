import Testing
@testable import DShift

struct CodexEventLogTests {
    @Test func collectsProgressAndFinalMessage() {
        var log = CodexEventLog()
        let lines = [
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Opening Messages**\nmore"}}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"mcp_tool_call","server":"computer-use","tool":"click","arguments":{"app":"Messages","element_index":4},"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"mcp_tool_call","server":"computer-use","tool":"click","status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Sent the message to Sam."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}"#,
        ]
        let changes = lines.map { log.apply($0) }

        #expect(changes == [false, false, true, true, false, false, false])
        #expect(log.steps == ["Opening Messages", "click in Messages"])
        #expect(log.finalMessage == "Sent the message to Sam.")
        #expect(log.failure == nil)
    }

    @Test func recordsFailures() {
        var log = CodexEventLog()
        _ = log.apply(#"{"type":"item.completed","item":{"id":"i","type":"mcp_tool_call","tool":"type_text","status":"failed"}}"#)
        _ = log.apply(#"{"type":"turn.failed","error":{"message":"computer use is not enabled"}}"#)
        #expect(log.steps == ["type_text failed"])
        #expect(log.failure == "computer use is not enabled")
    }

    @Test func ignoresNoise() {
        var log = CodexEventLog()
        let changedOnGarbage = log.apply("not json")
        let changedOnUnknownItem = log.apply(#"{"type":"item.updated","item":{"type":"todo_list"}}"#)
        #expect(!changedOnGarbage)
        #expect(!changedOnUnknownItem)
        #expect(log.steps.isEmpty)
    }
}
