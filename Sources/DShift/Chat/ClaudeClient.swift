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

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No API key. Set ANTHROPIC_API_KEY in .env (see .env.example) or export it."
        case .http(let status, let body):
            "HTTP \(status): \(body)"
        case .stream(let message):
            message
        }
    }
}

/// Streams events from the Messages API over raw HTTP (there is no official Swift SDK).
enum ClaudeClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5-5"
    // Low effort keeps sidebar answers snappy; raise to "medium" or "high" if answers feel shallow.
    private static let effort = "low"

    static func stream(system: String, messages: [JSON], tools: [JSON]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages, tools: tools)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ClaudeError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        for event in try parseEvents(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRequest(system: String, messages: [JSON], tools: [JSON]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        guard let apiKey = Config.value("ANTHROPIC_API_KEY") else { throw ClaudeError.missingAPIKey }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: JSON = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"],
            "fallbacks": "default",
        ]
        if !tools.isEmpty { body["tools"] = tools }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseEvents(_ line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data: "),
              let event = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? JSON
        else { return [] }

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
            throw ClaudeError.stream(message ?? "Unknown streaming error")
        default:
            return []
        }
    }
}
