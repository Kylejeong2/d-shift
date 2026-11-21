import CoreGraphics
import Testing

@testable import DShift

struct GestureRecognizerTests {
    private enum Shape {
        case point, open, closed
    }

    private static func hand(_ shape: Shape, at palm: CGPoint, spread: CGFloat = 1) -> HandSample {
        var joints: [HandJoint: CGPoint] = [.wrist: CGPoint(x: palm.x, y: palm.y + 100), .middleMCP: palm]
        let fingers: [(HandJoint, HandJoint, HandJoint, CGFloat)] = [
            (.indexMCP, .indexPIP, .indexTip, -24), (.middleMCP, .middlePIP, .middleTip, 0),
            (.ringMCP, .ringPIP, .ringTip, 22), (.littleMCP, .littlePIP, .littleTip, 42),
        ]
        for (index, (base, middle, tip, offset)) in fingers.enumerated() {
            let mcp = CGPoint(x: palm.x + offset, y: palm.y)
            joints[base] = mcp
            let extended = shape == .open || (shape == .point && index == 0)
            joints[middle] = CGPoint(x: mcp.x + offset * (spread - 1), y: mcp.y - (extended ? 35 : 30))
            joints[tip] = CGPoint(x: mcp.x + offset * (spread - 1) * 2, y: mcp.y + (extended ? -80 : 10))
        }
        joints[.thumbTip] = CGPoint(x: palm.x - 40 - 40 * spread, y: palm.y - 10)
        return HandSample(joints: joints)
    }

    private static func run(
        _ recognizer: inout GestureRecognizer, _ frames: [[HandSample]], from start: Double = 0,
        isOverItem: (CGPoint) -> Bool = { _ in false }
    ) -> [GestureEvent] {
        frames.enumerated().flatMap { index, samples in
            recognizer.update(samples, at: start + Double(index) / 30, isOverItem: isOverItem).events
        }
    }

    @Test func classifiesPoses() {
        #expect(HandFeatures(Self.hand(.point, at: .zero).joints)?.pose == .point)
        #expect(HandFeatures(Self.hand(.open, at: .zero).joints)?.pose == .open)
        #expect(HandFeatures(Self.hand(.closed, at: .zero).joints)?.pose == .closed)
    }

    @Test func pointingDrawsUntilTheHandCloses() {
        var recognizer = GestureRecognizer()
        let frames =
            (0..<10).map { [Self.hand(.point, at: CGPoint(x: 400 + CGFloat($0) * 10, y: 400))] }
            + (0..<5).map { _ in [Self.hand(.closed, at: CGPoint(x: 500, y: 400))] }
        let phases = Self.run(&recognizer, frames).compactMap { event -> GesturePhase? in
            if case .draw(_, let phase, _) = event { phase } else { nil }
        }
        #expect(phases.first == .began)
        #expect(phases.last == .ended)
        #expect(phases.filter { $0 == .ended }.count == 1)
    }

    @Test func fistNeverDrawsOrHolds() {
        var recognizer = GestureRecognizer()
        let events = Self.run(
            &recognizer, (0..<40).map { _ in [Self.hand(.closed, at: CGPoint(x: 400, y: 400))] },
            isOverItem: { _ in true })
        #expect(events.isEmpty)
    }

    @Test func stillOpenHandOverItemPicksUpMovesScalesAndDrops() {
        var recognizer = GestureRecognizer()
        let still = (0..<20).map { _ in [Self.hand(.open, at: CGPoint(x: 400, y: 400))] }
        let carry = (0..<15).map { [Self.hand(.open, at: CGPoint(x: 400 + CGFloat($0) * 20, y: 400), spread: 3)] }
        let drop = (0..<6).map { _ in [Self.hand(.closed, at: CGPoint(x: 700, y: 400))] }
        let events = Self.run(&recognizer, still + carry + drop, isOverItem: { _ in true })
        let holds = events.compactMap { event -> (GesturePhase, CGPoint, CGFloat)? in
            if case .hold(_, let phase, let point, let scale) = event { (phase, point, scale) } else { nil }
        }
        #expect(holds.first?.0 == .began)
        #expect(holds.last?.0 == .ended)
        let lastMove = holds.last { $0.0 == .moved }
        #expect((lastMove?.1.x ?? 0) > 600)
        #expect((lastMove?.2 ?? 0) > 1.3)
        #expect((holds.last?.2 ?? 0) > 1.3)
    }

    @Test func openHandAwayFromItemsDoesNothing() {
        var recognizer = GestureRecognizer()
        let events = Self.run(&recognizer, (0..<30).map { _ in [Self.hand(.open, at: CGPoint(x: 400, y: 400))] })
        #expect(events.isEmpty)
    }

    @Test func rubbingErasesInsteadOfPickingUp() {
        var recognizer = GestureRecognizer()
        let frames = (0..<30).map { step -> [HandSample] in
            let phase = CGFloat(step % 6)
            return [Self.hand(.open, at: CGPoint(x: 400 + (phase < 3 ? phase : 6 - phase) * 25, y: 400))]
        }
        let events = Self.run(&recognizer, frames, isOverItem: { _ in true })
        #expect(events.contains { if case .rub = $0 { true } else { false } })
        #expect(!events.contains { if case .hold(_, .began, _, _) = $0 { true } else { false } })
    }

    @Test func handsKeepTheirIdsWhileMoving() {
        var recognizer = GestureRecognizer()
        var ids: Set<Int> = []
        for step in 0..<10 {
            let frame = recognizer.update(
                [
                    Self.hand(.open, at: CGPoint(x: 300 + CGFloat(step) * 15, y: 400)),
                    Self.hand(.open, at: CGPoint(x: 1200 - CGFloat(step) * 15, y: 400)),
                ], at: Double(step) / 30)
            ids.formUnion(frame.pointers.map(\.hand))
        }
        #expect(ids.count == 2)
    }

    @Test func lostHandEndsDrawing() {
        var recognizer = GestureRecognizer()
        _ = Self.run(&recognizer, (0..<5).map { _ in [Self.hand(.point, at: CGPoint(x: 400, y: 400))] })
        let frame = recognizer.update([], at: 2)
        #expect(frame.events.contains { if case .draw(_, .ended, _) = $0 { true } else { false } })
        #expect(frame.pointers.isEmpty)
    }

    @Test func resizeRespondsDirectlyWithinTheHandsRange() {
        #expect(GestureRecognizer.directScale(GestureRecognizer.spreadProgress(1.2, from: 0.9)) == 3)
        #expect(GestureRecognizer.directScale(GestureRecognizer.spreadProgress(0.15, from: 0.9)) < 0.4)
        #expect(GestureRecognizer.spreadProgress(0.6, from: 0.6) == 0)
    }

    @Test func holdingFullySpreadKeepsGrowing() {
        var recognizer = GestureRecognizer()
        let still = (0..<20).map { _ in [Self.hand(.open, at: CGPoint(x: 400, y: 400))] }
        let spread = (0..<90).map { _ in [Self.hand(.open, at: CGPoint(x: 400, y: 400), spread: 4)] }
        let events = Self.run(&recognizer, still + spread, isOverItem: { _ in true })
        let lastScale =
            events.compactMap { event -> CGFloat? in
                if case .hold(_, .moved, _, let scale) = event { scale } else { nil }
            }.last ?? 0
        #expect(lastScale > 8)
    }

}
