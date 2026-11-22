import Foundation

/// Token counts reported by one Messages API response.
struct TokenUsage {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    /// `message_start` and `message_delta` both carry usage; later values are cumulative, so they overwrite.
    mutating func merge(_ fields: JSON) {
        if let value = fields["input_tokens"] as? Int { input = value }
        if let value = fields["output_tokens"] as? Int { output = value }
        if let value = fields["cache_read_input_tokens"] as? Int { cacheRead = value }
        if let value = fields["cache_creation_input_tokens"] as? Int { cacheWrite = value }
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// Per-chat usage: session totals plus how full the context window was on the latest request.
struct ChatUsage {
    static let contextWindow = 131_072

    private(set) var totals = TokenUsage()
    private(set) var requests = 0
    private(set) var contextTokens = 0

    mutating func record(_ usage: TokenUsage) {
        totals = totals + usage
        requests += 1
        contextTokens = usage.input + usage.cacheRead + usage.cacheWrite + usage.output
    }

    var contextFraction: Double {
        Double(contextTokens) / Double(Self.contextWindow)
    }
}

/// Live view of the model's output while it generates: a tail of its reasoning, streamed chunks so far, and the
/// rate of the last reply. Kept apart from `ChatModel` so per-token updates only redraw the views that show them.
@MainActor
final class GenerationProgress: ObservableObject {
    private static let reasoningTailLength = 600

    @Published private(set) var reasoning = ""
    @Published private(set) var chunks = 0
    @Published private(set) var startedGeneratingAt: Date?
    @Published private(set) var lastTokensPerSecond: Double?

    func reset() {
        reasoning = ""
        chunks = 0
        startedGeneratingAt = nil
    }

    func receive(reasoning delta: String? = nil) {
        if startedGeneratingAt == nil { startedGeneratingAt = Date() }
        chunks += 1
        guard let delta else { return }
        reasoning = String((reasoning + delta).suffix(Self.reasoningTailLength))
    }

    func finish(outputTokens: Int) {
        guard let startedGeneratingAt, outputTokens > 0 else { return }
        let seconds = Date().timeIntervalSince(startedGeneratingAt)
        if seconds > 0.2 { lastTokensPerSecond = Double(outputTokens) / seconds }
    }
}
