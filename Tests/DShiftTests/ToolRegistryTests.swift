import Testing
@testable import DShift

@MainActor
private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echoes text."
    let inputSchema: JSON = [
        "type": "object",
        "properties": ["text": ["type": "string"], "count": ["type": "integer"]],
        "required": ["text", "count"],
    ]
    func requiresApproval(for input: JSON) -> Bool { false }
    func run(_ input: JSON) async throws -> ToolOutput { ToolOutput(text: input["text"] as? String ?? "") }
}

@MainActor
struct ToolRegistryTests {
    let registry = ToolRegistry(tools: [EchoTool()])

    @Test func definitionsExposeSchemaWithEagerStreaming() {
        let definition = registry.definitions[0]
        #expect(definition["name"] as? String == "echo")
        #expect(definition["eager_input_streaming"] as? Bool == true)
        #expect(definition["input_schema"] != nil)
    }

    @Test func looksUpToolsByName() throws {
        #expect(try registry.tool(named: "echo").name == "echo")
        #expect(throws: ToolError.self) { try registry.tool(named: "missing") }
    }

    @Test func validatesRequiredFields() throws {
        let tool = try registry.tool(named: "echo")
        try registry.validate(["text": "hi", "count": 0], for: tool)
        #expect(throws: ToolError.self) { try registry.validate(["text": "hi"], for: tool) }
        #expect(throws: ToolError.self) { try registry.validate(["text": "", "count": 1], for: tool) }
        #expect(throws: ToolError.self) { try registry.validate(["text": 5, "count": 1], for: tool) }
    }

    @Test func toolDefaultsAreVisibleAndUnlimited() async throws {
        let tool = EchoTool()
        #expect(!tool.isHidden)
        #expect(tool.maxCallsPerTurn == nil)
        let output = try await tool.run(["text": "yo"], progress: { _ in }, requestAccess: { _ in .deny })
        #expect(output.text == "yo")
    }
}
