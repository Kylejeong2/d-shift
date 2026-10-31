import Testing

@testable import DShift

@MainActor
struct ToolUseRepairTests {
    @Test func fillsMissingToolResultBeforeNextUserMessage() {
        var messages: [JSON] = [
            ["role": "user", "content": [["type": "text", "text": "go to slack"]]],
            [
                "role": "assistant",
                "content": [["type": "tool_use", "id": "t1", "name": "use_computer", "input": [:]]],
            ],
            ["role": "user", "content": [["type": "text", "text": "and dont send it"]]],
        ]
        ChatModel.repairDanglingToolUses(&messages)
        let content = messages[2]["content"] as? [JSON] ?? []
        #expect(messages.count == 3)
        #expect(content.first?["type"] as? String == "tool_result")
        #expect(content.first?["tool_use_id"] as? String == "t1")
        #expect(content.last?["text"] as? String == "and dont send it")
    }

    @Test func insertsResultMessageWhenToolUseIsLast() {
        var messages: [JSON] = [
            ["role": "user", "content": [["type": "text", "text": "hi"]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "read_screen", "input": [:]]]],
        ]
        ChatModel.repairDanglingToolUses(&messages)
        #expect(messages.count == 3)
        #expect(messages[2]["role"] as? String == "user")
    }

    @Test func leavesAnsweredToolUsesAlone() {
        var messages: [JSON] = [
            ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "read_screen", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]],
        ]
        ChatModel.repairDanglingToolUses(&messages)
        #expect((messages[1]["content"] as? [JSON])?.count == 1)
    }
}
