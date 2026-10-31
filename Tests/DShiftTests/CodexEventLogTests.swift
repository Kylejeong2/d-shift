import Testing

@testable import DShift

struct CodexEventLogTests {
    @Test func collectsProgressAndFinalMessage() {
        var log = CodexEventLog()
        let events: [(String, JSON)] = [
            ("turn/started", [:]),
            (
                "item/completed",
                ["item": ["type": "agentMessage", "phase": "commentary", "text": "Opening Messages\nmore"]]
            ),
            ("item/started", ["item": ["type": "mcpToolCall", "tool": "js", "arguments": ["title": "Click Send"]]]),
            ("item/completed", ["item": ["type": "mcpToolCall", "tool": "js", "status": "completed"]]),
            (
                "item/completed",
                ["item": ["type": "agentMessage", "phase": "final_answer", "text": "Sent the message to Sam."]]
            ),
            ("turn/completed", ["turn": ["status": "completed"]]),
        ]
        let changes = events.map { log.apply(method: $0.0, params: $0.1) }

        #expect(changes == [false, true, true, false, false, false])
        #expect(log.steps == ["Opening Messages", "Click Send"])
        #expect(log.finalMessage == "Sent the message to Sam.")
        #expect(log.failure == nil)
        #expect(log.isDone)
    }

    @Test func recordsFailures() {
        var log = CodexEventLog()
        _ = log.apply(
            method: "item/completed",
            params: ["item": ["type": "mcpToolCall", "tool": "type_text", "status": "failed"]])
        _ = log.apply(method: "turn/completed", params: ["turn": ["error": ["message": "computer use is not enabled"]]])
        #expect(log.steps == ["type_text failed"])
        #expect(log.failure == "computer use is not enabled")
    }

    @Test func recordsBlockedApps() {
        var log = CodexEventLog()
        let notApproved: JSON = [
            "item": [
                "type": "mcpToolCall", "tool": "js", "status": "failed",
                "result": ["content": [["type": "text", "text": "Computer Use was not approved to use Slack"]]],
            ]
        ]
        let safety: JSON = [
            "item": [
                "type": "mcpToolCall", "tool": "js", "status": "failed",
                "error": [
                    "message": "Computer Use is not allowed to use the app 'com.mitchellh.ghostty' for safety reasons."
                ],
            ]
        ]
        _ = log.apply(method: "item/completed", params: notApproved)
        _ = log.apply(method: "item/completed", params: safety)
        #expect(
            log.blockedApps == [
                "Slack: not approved", "com.mitchellh.ghostty: blocked for safety (Codex never controls this app)",
            ])
    }

    @Test func readsAppNameFromApprovalPrompt() {
        #expect(CodexEventLog.appName(inApprovalPrompt: #"Allow Computer Use to use "Slack"?"#) == "Slack")
        #expect(CodexEventLog.appName(inApprovalPrompt: "Allow it?") == nil)
    }

    @Test func ignoresNoise() {
        var log = CodexEventLog()
        let changed = log.apply(method: "item/updated", params: ["item": ["type": "todo_list"]])
        #expect(!changed)
        #expect(log.steps.isEmpty)
    }
}
