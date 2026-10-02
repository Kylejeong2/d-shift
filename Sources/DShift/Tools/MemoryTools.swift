import Foundation

struct SaveMemoryTool: Tool {
    let name = "save_memory"
    let description = "Save a durable fact about the user (preferences, people, projects, writing style) to their local memory. Only save things likely to stay true and be useful later. The user approves each save."
    let inputSchema: JSON = [
        "type": "object",
        "properties": ["note": ["type": "string", "description": "One concise fact, written in third person."]],
        "required": ["note"],
        "additionalProperties": false,
    ]
    func requiresApproval(for input: JSON) -> Bool { true }

    func run(_ input: JSON) async throws -> ToolOutput {
        try Memory.remember(input["note"] as? String ?? "")
        return ToolOutput(text: "Saved.")
    }
}
