import AppKit

/// Watches events both while other apps are frontmost (global) and while D-Shift is (local). Removed on deinit.
final class EventMonitor {
    private var monitors: [Any] = []

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping @MainActor (NSEvent) -> Void) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handler(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Calls `handler` whenever Esc is pressed.
    static func escape(_ handler: @escaping @MainActor () -> Void) -> EventMonitor {
        EventMonitor(matching: .keyDown) { if $0.keyCode == 53 { handler() } }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }
}
