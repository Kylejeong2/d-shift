import AppKit
import ScreenCaptureKit

/// What a tool hands back to Claude: text, plus an optional image sent as an image block.
struct ToolOutput {
    var text: String
    var jpeg: Data? = nil
}

/// A client-side tool Claude can call. Return true from `requiresApproval` for any input that could change something.
@MainActor
protocol Tool {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSON { get }
    func requiresApproval(for input: JSON) -> Bool
    func run(_ input: JSON) async throws -> ToolOutput
}

enum ToolError: LocalizedError {
    case unknownTool(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidInput(let reason): "Invalid input: \(reason)"
        }
    }
}

@MainActor
struct ToolRegistry {
    let tools: [Tool]

    var definitions: [JSON] {
        tools.map {
            [
                "name": $0.name,
                "description": $0.description,
                "input_schema": $0.inputSchema,
                "eager_input_streaming": true,
            ]
        }
    }

    func tool(named name: String) throws -> Tool {
        guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError.unknownTool(name) }
        return tool
    }

    /// Eager input streaming skips server-side validation, so check required fields before running.
    func validate(_ input: JSON, for tool: Tool) throws {
        let required = tool.inputSchema["required"] as? [String] ?? []
        let properties = tool.inputSchema["properties"] as? [String: JSON] ?? [:]
        for key in required {
            guard let value = input[key] else { throw ToolError.invalidInput("missing \"\(key)\"") }
            if properties[key]?["type"] as? String == "string", (value as? String)?.isEmpty != false {
                throw ToolError.invalidInput("\"\(key)\" must be a non-empty string")
            }
        }
    }
}
