import AppKit

/// Fires when Control and Shift are pressed together and released with no other key in between, like a tap.
/// Used for appshots: capture the focused window into the current chat.
final class ModifierChordMonitor {
    private static let chord: NSEvent.ModifierFlags = [.control, .shift]
    private static let maxHoldDuration: TimeInterval = 0.8

    private let onTrigger: () -> Void
    private var monitor: EventMonitor?
    private var chordStartedAt: TimeInterval?
    private var isCancelled = false

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        monitor = EventMonitor(matching: [.flagsChanged, .keyDown]) { [weak self] in self?.handle($0) }
    }

    private func handle(_ event: NSEvent) {
        // Any real key press means a shortcut like Ctrl+Shift+Tab, not a tap of the chord.
        guard event.type == .flagsChanged else {
            if chordStartedAt != nil { cancel() }
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([
            .capsLock, .numericPad, .function,
        ])
        if flags.isEmpty {
            if !isCancelled, let start = chordStartedAt, event.timestamp - start < Self.maxHoldDuration {
                onTrigger()
            }
            chordStartedAt = nil
            isCancelled = false
        } else if !Self.chord.isSuperset(of: flags) {
            cancel()  // Cmd or Option joined in
        } else if flags == Self.chord, chordStartedAt == nil, !isCancelled {
            chordStartedAt = event.timestamp
        }
    }

    /// Ignores everything until all modifiers are released.
    private func cancel() {
        chordStartedAt = nil
        isCancelled = true
    }
}
