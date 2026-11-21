import CoreGraphics
import Foundation

struct HandSample: Sendable {
    let joints: [HandJoint: CGPoint]
}

enum HandPose: String, Equatable {
    case point, open, closed, between
}

enum HandAction: String, Equatable {
    case idle, drawing, holding, erasing
}

struct HandPointer: Equatable {
    let hand: Int
    let point: CGPoint
    let pose: HandPose
    let action: HandAction
    let scale: CGFloat
    let joints: [HandJoint: CGPoint]
}

enum GesturePhase: String, Equatable {
    case began, moved, ended
}

enum GestureEvent: Equatable {
    case draw(hand: Int, phase: GesturePhase, at: CGPoint)
    case hold(hand: Int, phase: GesturePhase, at: CGPoint, scale: CGFloat)
    case rub(at: CGPoint, radius: CGFloat)
}

struct GestureFrame: Equatable {
    var pointers: [HandPointer] = []
    var events: [GestureEvent] = []
}

struct HandFeatures {
    let palm: CGPoint
    let indexTip: CGPoint
    let size: CGFloat
    let extensions: [CGFloat]
    let spread: CGFloat?

    init?(_ joints: [HandJoint: CGPoint]) {
        guard let wrist = joints[.wrist], let middleBase = joints[.middleMCP], let indexTip = joints[.indexTip] else {
            return nil
        }
        let distance = { (a: CGPoint, b: CGPoint) in hypot(a.x - b.x, a.y - b.y) }
        size = max(1, distance(wrist, middleBase))
        palm = middleBase
        self.indexTip = indexTip
        let fingers: [(HandJoint, HandJoint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        var extensions: [CGFloat] = []
        for (tipJoint, middleJoint) in fingers {
            guard let tip = joints[tipJoint], let middle = joints[middleJoint] else { return nil }
            extensions.append(distance(wrist, tip) / max(1, distance(wrist, middle)))
        }
        self.extensions = extensions
        let tips = [HandJoint.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip].compactMap { joints[$0] }
        if tips.count == 5 {
            let center = CGPoint(x: tips.map(\.x).reduce(0, +) / 5, y: tips.map(\.y).reduce(0, +) / 5)
            spread = tips.map { distance($0, center) }.reduce(0, +) / 5 / size
        } else {
            spread = nil
        }
    }

    var pose: HandPose {
        let others = extensions.dropFirst()
        if extensions[0] > 1.15, others.max()! < 0.9 { return .point }
        if extensions.min()! > 1.2 { return .open }
        if extensions.max()! < 0.85 { return .closed }
        return .between
    }
}

struct OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private var value: CGPoint?
    private var velocity = CGPoint.zero
    private var lastTime: TimeInterval?

    init(minCutoff: Double = 1.2, beta: Double = 0.015) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let previous = value, let lastTime, time > lastTime else {
            value = point
            lastTime = time
            return point
        }
        let elapsed = time - lastTime
        let alpha = { (cutoff: Double) in 1 / (1 + 1 / (2 * .pi * cutoff * elapsed)) }
        let rawVelocity = CGPoint(x: (point.x - previous.x) / elapsed, y: (point.y - previous.y) / elapsed)
        let velocityAlpha = alpha(1.0)
        velocity = CGPoint(
            x: velocity.x + (rawVelocity.x - velocity.x) * velocityAlpha,
            y: velocity.y + (rawVelocity.y - velocity.y) * velocityAlpha)
        let pointAlpha = alpha(minCutoff + beta * hypot(velocity.x, velocity.y))
        let next = CGPoint(
            x: previous.x + (point.x - previous.x) * pointAlpha, y: previous.y + (point.y - previous.y) * pointAlpha)
        value = next
        self.lastTime = time
        return next
    }
}

struct GestureRecognizer {
    static let stableFrames = 3
    static let pickUpDwell: TimeInterval = 0.35
    static let pickUpStillness: CGFloat = 0.35
    static let lostHandGrace: TimeInterval = 0.4
    static let rubWindow: TimeInterval = 0.8
    static let rubReversalsToStart = 3
    static let scaleRange: ClosedRange<CGFloat> = 0.1...12
    static let continuousRate: CGFloat = 0.7
    static let continuousThreshold: CGFloat = 0.8
    static let matchDistance: CGFloat = 400
    static let dropRollback: TimeInterval = 0.3

    private struct HandState {
        var palmFilter = OneEuroFilter()
        var tipFilter = OneEuroFilter()
        var palm: CGPoint = .zero
        var tip: CGPoint = .zero
        var size: CGFloat = 100
        var lastSeen: TimeInterval = 0
        var pose: HandPose = .between
        var candidate: HandPose?
        var candidateCount = 0
        var action: HandAction = .idle
        var stillSince: (time: TimeInterval, at: CGPoint)?
        var holdSpread: CGFloat = 1
        var holdBoost: CGFloat = 0
        var lastHoldUpdate: TimeInterval = 0
        var smoothedSpread: CGFloat?
        var scaleHistory: [(time: TimeInterval, scale: CGFloat)] = []
        var palmTrace: [(time: TimeInterval, point: CGPoint)] = []
        var joints: [HandJoint: CGPoint] = [:]

        var scale: CGFloat { scaleHistory.last?.scale ?? 1 }

        func settledScale(at time: TimeInterval) -> CGFloat {
            scaleHistory.last { time - $0.time >= GestureRecognizer.dropRollback }?.scale ?? scaleHistory.first?.scale
                ?? 1
        }
    }

    private var hands: [Int: HandState] = [:]
    private var nextHandId = 0

    mutating func update(
        _ samples: [HandSample], at time: TimeInterval, isOverItem: (CGPoint) -> Bool = { _ in false }
    ) -> GestureFrame {
        var frame = GestureFrame()
        let measured = samples.compactMap { sample in HandFeatures(sample.joints).map { (sample, $0) } }
        for (hand, sample, features) in assignIds(measured) {
            var state = hands[hand] ?? HandState()
            state.lastSeen = time
            state.size = features.size
            state.palm = state.palmFilter.filter(features.palm, at: time)
            state.tip = state.tipFilter.filter(features.indexTip, at: time)
            state.joints = sample.joints
            if let spread = features.spread {
                state.smoothedSpread = state.smoothedSpread.map { $0 + (spread - $0) * 0.45 } ?? spread
            }
            Self.updatePose(&state, raw: features.pose)
            frame.events += Self.updateAction(&state, hand: hand, time: time, isOverItem: isOverItem)
            hands[hand] = state
        }

        for (hand, state) in hands where time - state.lastSeen > Self.lostHandGrace {
            switch state.action {
            case .drawing: frame.events.append(.draw(hand: hand, phase: .ended, at: state.tip))
            case .holding:
                frame.events.append(
                    .hold(hand: hand, phase: .ended, at: state.palm, scale: state.settledScale(at: time)))
            case .idle, .erasing: break
            }
            hands[hand] = nil
        }

        frame.pointers = hands.keys.sorted().compactMap { hand in
            guard let state = hands[hand], time - state.lastSeen < 0.15 else { return nil }
            let usesFingertip = state.pose == .point || state.action == .drawing
            return HandPointer(
                hand: hand, point: usesFingertip ? state.tip : state.palm, pose: state.pose, action: state.action,
                scale: state.scale, joints: state.joints)
        }
        return frame
    }

    private mutating func assignIds(_ measured: [(HandSample, HandFeatures)]) -> [(Int, HandSample, HandFeatures)] {
        var available = Set(hands.keys)
        return measured.map { sample, features in
            let nearest = available.min {
                Self.distance(hands[$0]!.palm, features.palm) < Self.distance(hands[$1]!.palm, features.palm)
            }
            if let nearest, Self.distance(hands[nearest]!.palm, features.palm) < Self.matchDistance {
                available.remove(nearest)
                return (nearest, sample, features)
            }
            nextHandId += 1
            return (nextHandId, sample, features)
        }
    }

    private static func updatePose(_ state: inout HandState, raw: HandPose) {
        if raw == state.pose {
            state.candidate = nil
            state.candidateCount = 0
        } else if raw == state.candidate {
            state.candidateCount += 1
            if state.candidateCount >= stableFrames - 1 {
                state.pose = raw
                state.candidate = nil
                state.candidateCount = 0
            }
        } else {
            state.candidate = raw
            state.candidateCount = 0
        }
    }

    private static func updateAction(
        _ state: inout HandState, hand: Int, time: TimeInterval, isOverItem: (CGPoint) -> Bool
    ) -> [GestureEvent] {
        var events: [GestureEvent] = []
        state.palmTrace.append((time, state.palm))
        state.palmTrace.removeAll { time - $0.time > rubWindow }
        let isRubbing =
            state.pose == .open
            && reversals(in: state.palmTrace.map(\.point), handSize: state.size)
                >= (state.action == .erasing ? 2 : rubReversalsToStart)

        switch state.action {
        case .drawing:
            if state.pose == .open || state.pose == .closed {
                events.append(.draw(hand: hand, phase: .ended, at: state.tip))
                state.action = .idle
            } else {
                events.append(.draw(hand: hand, phase: .moved, at: state.tip))
            }
        case .holding:
            if isRubbing {
                events.append(.hold(hand: hand, phase: .ended, at: state.palm, scale: state.scale))
                state.action = .erasing
            } else if state.pose == .closed || state.pose == .point {
                events.append(.hold(hand: hand, phase: .ended, at: state.palm, scale: state.settledScale(at: time)))
                state.action = .idle
            } else {
                if let spread = state.smoothedSpread {
                    let progress = Self.spreadProgress(spread, from: state.holdSpread)
                    let elapsed = min(0.1, time - state.lastHoldUpdate)
                    state.lastHoldUpdate = time
                    if abs(progress) >= continuousThreshold {
                        state.holdBoost += (progress > 0 ? 1 : -1) * continuousRate * elapsed
                    }
                    let scale = min(
                        scaleRange.upperBound,
                        max(scaleRange.lowerBound, Self.directScale(progress) * exp(state.holdBoost)))
                    state.scaleHistory.append((time, scale))
                    state.scaleHistory.removeAll { time - $0.time > dropRollback * 2 }
                }
                events.append(.hold(hand: hand, phase: .moved, at: state.palm, scale: state.scale))
            }
        case .erasing:
            if !isRubbing { state.action = .idle }
        case .idle:
            if state.pose == .point {
                state.action = .drawing
                state.stillSince = nil
                events.append(.draw(hand: hand, phase: .began, at: state.tip))
            } else if isRubbing {
                state.action = .erasing
                state.stillSince = nil
            } else if state.pose == .open {
                if let still = state.stillSince, distance(still.at, state.palm) < state.size * pickUpStillness {
                    if time - still.time >= pickUpDwell, isOverItem(state.palm) {
                        state.action = .holding
                        state.holdSpread = max(0.1, state.smoothedSpread ?? 0.6)
                        state.holdBoost = 0
                        state.lastHoldUpdate = time
                        state.scaleHistory = [(time, 1)]
                        state.stillSince = nil
                        events.append(.hold(hand: hand, phase: .began, at: state.palm, scale: 1))
                    }
                } else {
                    state.stillSince = (time, state.palm)
                }
            } else {
                state.stillSince = nil
            }
        }
        if state.action == .erasing {
            events.append(.rub(at: state.palm, radius: state.size * 1.4))
        }
        return events
    }

    static func spreadProgress(_ spread: CGFloat, from start: CGFloat) -> CGFloat {
        let widest = max(1.0, start + 0.1)
        let tightest = min(0.15, start - 0.3)
        if spread >= start { return min(1, (spread - start) / (widest - start)) }
        return -min(1, (start - spread) / (start - tightest))
    }

    static func directScale(_ progress: CGFloat) -> CGFloat {
        progress >= 0 ? 1 + progress * 2 : 1 + progress * 0.65
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func reversals(in points: [CGPoint], handSize: CGFloat) -> Int {
        guard points.count > 2 else { return 0 }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let spanX = xs.max()! - xs.min()!
        let spanY = ys.max()! - ys.min()!
        guard max(spanX, spanY) < handSize * 3.5 else { return 0 }
        let values = spanX >= spanY ? xs : ys
        let minimumTravel = handSize * 0.12
        var count = 0
        var direction: CGFloat = 0
        var anchor = values[0]
        for value in values.dropFirst() {
            let travel = value - anchor
            if direction == 0 {
                if abs(travel) >= minimumTravel {
                    direction = travel < 0 ? -1 : 1
                    anchor = value
                }
            } else if travel * direction > 0 {
                anchor = value
            } else if abs(travel) >= minimumTravel {
                count += 1
                direction = -direction
                anchor = value
            }
        }
        return count
    }
}
