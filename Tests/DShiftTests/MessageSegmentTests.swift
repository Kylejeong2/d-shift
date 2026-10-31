import Testing

@testable import DShift

struct MessageSegmentTests {
    @Test func splitsFencedCode() {
        let text = "Here:\n```swift\nlet a = 1\n```\nDone."
        #expect(MessageSegment.split(text) == [.prose("Here:"), .code("let a = 1"), .prose("Done.")])
    }

    @Test func keepsUnclosedFenceWhileStreaming() {
        #expect(MessageSegment.split("Look:\n```\n┌──┐") == [.prose("Look:"), .code("┌──┐")])
    }

    @Test func plainTextIsOneSegment() {
        #expect(MessageSegment.split("just text") == [.prose("just text")])
    }
}
