import Testing

@testable import DShift

struct TextZoomTests {
    @Test func stepsThroughLevelsAndClampsAtTheEnds() {
        #expect(TextZoom.step(1.0, by: 1) == 1.1)
        #expect(TextZoom.step(1.0, by: -1) == 0.9)
        #expect(TextZoom.step(0.8, by: -1) == 0.8)
        #expect(TextZoom.step(2.0, by: 1) == 2.0)
    }

    @Test func snapsOffGridValuesToTheNextLevel() {
        #expect(TextZoom.step(1.05, by: 0) == 1.1)
        #expect(TextZoom.step(3.0, by: -1) == 1.75)
    }
}
