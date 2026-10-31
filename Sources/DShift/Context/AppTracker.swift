import AppKit
import ApplicationServices

/// Follows the frontmost app (excluding the sidebar itself) and its focused window title in real time.
@MainActor
final class AppTracker: ObservableObject {
    @Published private(set) var app: NSRunningApplication?
    @Published private(set) var windowTitle = ""

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var observedWindow: AXUIElement?

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.track(app) }
        }
        track(NSWorkspace.shared.frontmostApplication)
    }

    fileprivate func handleAXNotification(_ name: String) {
        if name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
            observeFocusedWindowTitle()
        }
        refreshTitle()
    }

    private func track(_ newApp: NSRunningApplication?) {
        guard let newApp, newApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            Self.hasNormalWindow(newApp.processIdentifier)
        else { return }
        app = newApp
        observe(newApp)
        refreshTitle()
    }

    /// Recorders, launchers, and menu bar apps can take focus with only floating widgets on screen (Screen Studio's
    /// recording controls, for example). Those aren't what the user is looking at, so keep following the last app
    /// with an ordinary visible window. Reading window layers and bounds needs no Screen Recording permission.
    static func hasNormalWindow(_ pid: pid_t) -> Bool {
        let windows =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                window[kCGWindowLayer as String] as? Int == 0,
                (window[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return frame.width >= 200 && frame.height >= 150
        }
    }

    private func observe(_ app: NSRunningApplication) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedWindow = nil

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        appElement = element

        var newObserver: AXObserver?
        guard AXObserverCreate(app.processIdentifier, axNotificationCallback, &newObserver) == .success,
            let newObserver
        else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(newObserver, element, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observeFocusedWindowTitle()
    }

    private func observeFocusedWindowTitle() {
        guard let observer, let appElement else { return }
        if let observedWindow {
            AXObserverRemoveNotification(observer, observedWindow, kAXTitleChangedNotification as CFString)
        }
        observedWindow = AXSnapshot.element(appElement, kAXFocusedWindowAttribute)
        if let observedWindow {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, observedWindow, kAXTitleChangedNotification as CFString, refcon)
        }
    }

    private func refreshTitle() {
        let window = appElement.flatMap { AXSnapshot.element($0, kAXFocusedWindowAttribute) }
        windowTitle = window.flatMap { AXSnapshot.string($0, kAXTitleAttribute) } ?? ""
    }
}

private func axNotificationCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<AppTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.handleAXNotification(notification as String) }
}
