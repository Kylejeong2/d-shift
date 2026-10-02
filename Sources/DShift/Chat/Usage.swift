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
    static let contextWindow = 1_000_000
    // Claude Opus 5.5 list prices in dollars per million tokens. Cache writes are the 5-minute TTL rate (1.25x input).
    private static let inputPrice = 4.0
    private static let outputPrice = 20.0
    private static let cacheReadPrice = 0.20
    private static let cacheWritePrice = 5.0

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

    var cacheHitRate: Double {
        let prompt = totals.input + totals.cacheRead + totals.cacheWrite
        return prompt == 0 ? 0 : Double(totals.cacheRead) / Double(prompt)
    }

    var estimatedCost: Double {
        (Double(totals.input) * Self.inputPrice
            + Double(totals.output) * Self.outputPrice
            + Double(totals.cacheRead) * Self.cacheReadPrice
            + Double(totals.cacheWrite) * Self.cacheWritePrice) / 1_000_000
    }
}
