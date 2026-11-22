import Foundation

typealias JSON = [String: Any]

/// Raw Messages API stream events, at content-block granularity so text, thinking, and tool calls all flow through.
enum StreamEvent {
    case blockStart(index: Int, block: JSON)
    case blockDelta(index: Int, delta: JSON)
    case blockStop(index: Int)
    case stopReason(String)
    case usage(JSON)
}

enum InklingError: LocalizedError {
    case http(status: Int, body: String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            "HTTP \(status): \(body)"
        case .stream(let message):
            message
        }
    }
}

/// Streams events from Inkling 2 Mini served locally by Ollama through its Anthropic-compatible Messages endpoint.
enum InklingClient {
    static var host: String { Config.value("OLLAMA_HOST") ?? "http://localhost:11434" }
    private static var endpoint: URL { URL(string: host)!.appendingPathComponent("v1/messages") }
    /// A variant of inkling-2-mini with a 128K context window. Ollama ignores per-request context options and
    /// otherwise loads the model at 32K, silently truncating longer chats. See the README for how to create it.
    static var model: String { Config.value("INKLING_MODEL") ?? "inkling-2-mini-128k" }
    /// Shown under the chat input. A custom INKLING_MODEL shows its raw Ollama tag.
    static var displayName: String { model.hasPrefix("inkling-2-mini") ? "Inkling 2 Mini" : model }
    /// The model defaults to high effort, which takes several times longer for a typical sidebar answer.
    private static let effort = "low"

    static func stream(system: String, messages: [JSON], tools: [JSON]) -> AsyncThrowingStream<StreamEvent, Error> {
        ServerSentEvents.stream(
            { try makeRequest(system: system, messages: messages, tools: tools) },
            httpError: { status, body in
                InklingError.http(
                    status: status,
                    body: status == 404
                        ? "\(body) (model \(model) not found in Ollama; see the README setup steps)" : body)
            },
            parse: parseEvents
        )
    }

    private static func makeRequest(system: String, messages: [JSON], tools: [JSON]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: JSON = [
            "model": model,
            "max_tokens": 32000,
            "stream": true,
            "system": system,
            "messages": messages.map(withoutAnthropicServerBlocks),
            "output_config": ["effort": effort],
        ]
        if !tools.isEmpty { body["tools"] = tools }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Chats saved while D-Shift ran on Claude can hold Anthropic-hosted web search and fetch blocks.
    static func withoutAnthropicServerBlocks(_ message: JSON) -> JSON {
        guard let blocks = message["content"] as? [JSON] else { return message }
        var cleaned = message
        cleaned["content"] = blocks.filter { block in
            let type = block["type"] as? String ?? ""
            return type != "server_tool_use" && (type == "tool_result" || !type.hasSuffix("_tool_result"))
        }
        return cleaned
    }

    static func parseEvents(_ line: String) throws -> [StreamEvent] {
        guard let event = try ServerSentEvents.payload(line) else { return [] }

        let index = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "message_start":
            return ((event["message"] as? JSON)?["usage"] as? JSON).map { [.usage($0)] } ?? []
        case "content_block_start":
            return (event["content_block"] as? JSON).map { [.blockStart(index: index, block: $0)] } ?? []
        case "content_block_delta":
            return (event["delta"] as? JSON).map { [.blockDelta(index: index, delta: $0)] } ?? []
        case "content_block_stop":
            return [.blockStop(index: index)]
        case "message_delta":
            var events: [StreamEvent] = []
            if let reason = (event["delta"] as? JSON)?["stop_reason"] as? String { events.append(.stopReason(reason)) }
            if let usage = event["usage"] as? JSON { events.append(.usage(usage)) }
            return events
        case "error":
            let message = (event["error"] as? JSON)?["message"] as? String
            throw InklingError.stream(message ?? "Unknown streaming error")
        default:
            return []
        }
    }
}
