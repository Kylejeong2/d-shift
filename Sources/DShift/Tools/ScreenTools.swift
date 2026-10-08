import AppKit
import ScreenCaptureKit

struct ReadScreenTool: Tool {
    let tracker: AppTracker

    let isHidden = true
    let name = "read_screen"
    let description = "Re-read the accessibility tree of the app window the user is currently looking at. Use when the user says the screen changed or the snapshot in the conversation looks stale."
    let inputSchema: JSON = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        guard let app = tracker.app else { return ToolOutput(text: "No app is in focus.") }
        let context = await Task.detached { AXSnapshot.capture(app: app) }.value
        return ToolOutput(text: "App: \(context.appName)\nWindow: \(context.windowTitle)\n\n\(context.tree)")
    }
}

struct ScreenshotTool: Tool {
    private static let maxLongEdgePixels: CGFloat = 1568

    let tracker: AppTracker

    let maxCallsPerTurn: Int? = 1
    let name = "take_screenshot"
    let description = "Capture a screenshot of the window the user is looking at, or of their whole screen. Last resort: only when the accessibility snapshot lacks the visual information needed to answer (images, charts, canvas or design apps, layout or styling). Limited to one per question."
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "scope": ["type": "string", "enum": ["window", "screen"], "description": "\"window\" (default) for the focused window, \"screen\" for the whole display."],
        ],
        "additionalProperties": false,
    ]
    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return ToolOutput(text: "Screen Recording permission is not granted. Ask the user to enable it in System Settings > Privacy & Security > Screen Recording, then relaunch the sidebar.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let pid = tracker.app?.processIdentifier
        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
        }
        let window = appWindows.first { $0.title == tracker.windowTitle && !tracker.windowTitle.isEmpty }
            ?? appWindows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }

        let filter: SCContentFilter
        let frame: CGRect
        let description: String
        if input["scope"] as? String != "screen", let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
            frame = window.frame
            description = "Window \"\(window.title ?? "")\" of \(tracker.app?.localizedName ?? "the app")"
        } else {
            let display = content.displays.first { $0.frame.contains(window?.frame.origin ?? .zero) } ?? content.displays.first
            guard let display else { return ToolOutput(text: "No display found.") }
            // The sidebar shows up in user screenshots, but Claude's own screenshots leave it out.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            frame = display.frame
            description = "Full screen"
        }

        let configuration = SCStreamConfiguration()
        let scale = min(2, Self.maxLongEdgePixels / max(frame.width, frame.height))
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(frame.height * scale)
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return ToolOutput(text: "Failed to encode the screenshot.")
        }
        return ToolOutput(text: "\(description), \(image.width)x\(image.height).", jpeg: jpeg)
    }
}
