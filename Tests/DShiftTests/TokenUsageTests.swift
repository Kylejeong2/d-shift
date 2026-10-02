import Testing
@testable import DShift

struct TokenUsageTests {
    @Test func laterUsageEventsOverwriteCumulativeCounts() {
        var usage = TokenUsage()
        usage.merge(["input_tokens": 10, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 90, "output_tokens": 1])
        usage.merge(["output_tokens": 250])
        #expect(usage.input == 10)
        #expect(usage.cacheRead == 900)
        #expect(usage.cacheWrite == 90)
        #expect(usage.output == 250)
    }

    @Test func chatUsageTracksContextAndCost() {
        var chat = ChatUsage()
        chat.record(TokenUsage(input: 1_000, output: 500, cacheRead: 9_000, cacheWrite: 0))
        #expect(chat.contextTokens == 10_500)
        #expect(chat.requests == 1)
        #expect(chat.cacheHitRate == 0.9)
        #expect(abs(chat.estimatedCost - 0.0158) < 0.0001)
    }
}
