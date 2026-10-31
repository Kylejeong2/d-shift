import AppKit

/// Fires when Shift is tapped twice quickly with no other key or modifier in between.
final class DoubleShiftMonitor {
    private static let maxTapDuration: TimeInterval = 0.25
    private static let maxGapBetweenTaps: TimeInterval = 0.4
    private static let leftShiftKeyCode: UInt16 = 56
    private static let rightShiftKeyCode: UInt16 = 60

    private let onTrigger: () -> Void
    private var monitor: EventMonitor?
    private var shiftDownAt: TimeInterval?
    private var lastTapAt: TimeInterval = 0

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        monitor = EventMonitor(matching: [.flagsChanged, .keyDown]) { [weak self] in self?.handle($0) }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged,
            event.keyCode == Self.leftShiftKeyCode || event.keyCode == Self.rightShiftKeyCode
        else {
            reset()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if flags == .shift {
            shiftDownAt = event.timestamp
        } else if flags.isEmpty, let downAt = shiftDownAt {
            shiftDownAt = nil
            guard event.timestamp - downAt < Self.maxTapDuration else { return reset() }
            if event.timestamp - lastTapAt < Self.maxGapBetweenTaps {
                reset()
                onTrigger()
            } else {
                lastTapAt = event.timestamp
            }
        } else {
            reset()
        }
    }

    private func reset() {
        shiftDownAt = nil
        lastTapAt = 0
    }
}
