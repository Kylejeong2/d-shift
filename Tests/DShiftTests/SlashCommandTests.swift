import Testing
@testable import DShift

struct SlashCommandTests {
    @Test func matchesByPrefix() {
        #expect(SlashCommand.matches(for: "/") == SlashCommand.allCases)
        #expect(SlashCommand.matches(for: "/au") == [.auto])
        #expect(SlashCommand.matches(for: "/c") == [.clear, .copy])
    }

    @Test func ignoresOrdinaryText() {
        #expect(SlashCommand.matches(for: "hello").isEmpty)
        #expect(SlashCommand.matches(for: "/auto please").isEmpty)
        #expect(SlashCommand.exact("/nope") == nil)
        #expect(SlashCommand.exact("/AUTO") == .auto)
    }
}
