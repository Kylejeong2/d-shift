import Foundation

enum OpenAIStreamEvent {
    case text(String)
    case usage(input: Int, output: Int)
}

/// Streams text from the OpenAI Responses API. Used only for on-screen graphics, where GPT-6.1 Sol's Ultrafast
/// tier keeps the time to first pixel low; the chat itself stays on Claude.
enum OpenAIClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let model = "gpt-6.1-sol"
    private static let serviceTier = "ultrafast"
    // Ultrafast list prices in dollars per million tokens.
    static let inputPrice = 12.0
    static let outputPrice = 60.0

    static func costSummary(input: Int, output: Int) -> String {
        let cost = (Double(input) * inputPrice + Double(output) * outputPrice) / 1_000_000
        return "\(input) in / \(output) out, $\(String(format: "%.3f", cost))"
    }

    static var hasKey: Bool { Config.value("OPENAI_API_KEY") != nil }

    /// `effort` is the reasoning effort: more lets the model plan a design before it starts streaming.
    static func stream(
        instructions: String, input: String, jpeg: Data? = nil, effort: String = "medium", maxOutputTokens: Int
    ) -> AsyncThrowingStream<OpenAIStreamEvent, Error> {
        ServerSentEvents.stream(
            { try makeRequest(instructions: instructions, input: input, jpeg: jpeg, effort: effort, maxOutputTokens: maxOutputTokens) },
            httpError: { ToolError.failed("OpenAI HTTP \($0): \($1)") },
            parse: { try parseEvent($0).map { [$0] } ?? [] }
        )
    }

    private static func makeRequest(
        instructions: String, input: String, jpeg: Data?, effort: String, maxOutputTokens: Int
    ) throws -> URLRequest {
        guard let apiKey = Config.value("OPENAI_API_KEY") else {
            throw ToolError.failed("No OpenAI API key. Set one from the menu bar icon > Set OpenAI API Key, or OPENAI_API_KEY in .env.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var content: [JSON] = [["type": "input_text", "text": input]]
        if let jpeg {
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"])
        }
        let body: JSON = [
            "model": model,
            "service_tier": serviceTier,
            "instructions": instructions,
            "input": [["role": "user", "content": content]],
            "reasoning": ["effort": effort],
            "max_output_tokens": maxOutputTokens,
            "stream": true,
            "store": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseEvent(_ line: String) throws -> OpenAIStreamEvent? {
        guard let event = try? ServerSentEvents.payload(line) else { return nil }

        switch event["type"] as? String {
        case "response.output_text.delta":
            return (event["delta"] as? String).map { .text($0) }
        case "response.completed":
            let usage = (event["response"] as? JSON)?["usage"] as? JSON
            return .usage(input: usage?["input_tokens"] as? Int ?? 0, output: usage?["output_tokens"] as? Int ?? 0)
        case "response.failed":
            let message = ((event["response"] as? JSON)?["error"] as? JSON)?["message"] as? String
            throw ToolError.failed("OpenAI: \(message ?? "response failed")")
        case "error":
            throw ToolError.failed("OpenAI: \(event["message"] as? String ?? "streaming error")")
        default:
            return nil
        }
    }
}
