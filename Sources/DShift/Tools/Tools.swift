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
    /// Hidden tools run without a transcript row, for background work the user doesn't need to see.
    var isHidden: Bool { get }
    /// Caps how often the model may call this tool while answering one question.
    var maxCallsPerTurn: Int? { get }
    func run(_ input: JSON) async throws -> ToolOutput
    /// Long-running tools can report progress, shown live on their card. Defaults to `run(_:)`.
    func run(_ input: JSON, progress: @escaping (String) -> Void) async throws -> ToolOutput
}

extension Tool {
    var isHidden: Bool { false }
    var maxCallsPerTurn: Int? { nil }

    func run(_ input: JSON, progress: @escaping (String) -> Void) async throws -> ToolOutput {
        try await run(input)
    }
}

enum ToolError: LocalizedError {
    case unknownTool(String)
    case invalidInput(String)
    case limitReached(String, Int)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .invalidInput(let reason): "Invalid input: \(reason)"
        case .limitReached(let name, let limit): "\(name) can only be called \(limit) time(s) per question. Answer with what you have."
        case .failed(let reason): reason
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
