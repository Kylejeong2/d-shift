import AppKit
import ApplicationServices

struct ScreenContext: Equatable {
    let appName: String
    let windowTitle: String
    let tree: String
    /// Focused window in global screen points, top-left origin (the accessibility coordinate space).
    var windowFrame: CGRect? = nil
}

/// Serializes the focused window's accessibility tree into compact indented text for the model.
enum AXSnapshot {
    private static let maxNodesVisited = 3000
    private static let maxOutputChars = 60_000
    private static let maxValueChars = 500
    private static let maxDepth = 40
    /// Busy Electron apps can answer each attribute read slowly, so the whole walk gets a time budget.
    private static let timeBudget: TimeInterval = 1.5
    private static let structuralRoles: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea", "AXLayoutArea"]

    /// `includeFrames` appends each element's `[x,y wxh]` in global screen points, for drawing over it.
    static func capture(app: NSRunningApplication, includeFrames: Bool = false) -> ScreenContext {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Chrome and Electron only build their full tree once an assistive client asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
        guard let window = element(appElement, kAXFocusedWindowAttribute) ?? element(appElement, kAXMainWindowAttribute) else {
            return ScreenContext(appName: appName, windowTitle: "", tree: "(no accessible window)")
        }

        var walker = Walker(focused: element(appElement, kAXFocusedUIElementAttribute), includeFrames: includeFrames)
        walker.walk(window, depth: 0)

        var tree = walker.lines.joined(separator: "\n")
        if walker.truncated { tree += "\n(truncated)" }
        if let focused = walker.focused, let selection = string(focused, kAXSelectedTextAttribute), !selection.isEmpty {
            tree += "\n\nSelected text:\n\(selection.prefix(maxValueChars * 4))"
        }
        return ScreenContext(
            appName: appName, windowTitle: string(window, kAXTitleAttribute) ?? "", tree: tree, windowFrame: frame(window)
        )
    }

    private struct Walker {
        let focused: AXUIElement?
        let includeFrames: Bool
        var lines: [String] = []
        var visited = 0
        var outputChars = 0
        var truncated = false
        let deadline = Date().addingTimeInterval(timeBudget)

        mutating func walk(_ node: AXUIElement, depth: Int) {
            guard visited < maxNodesVisited, outputChars < maxOutputChars, depth < maxDepth, Date() < deadline else {
                truncated = true
                return
            }
            visited += 1

            let role = string(node, kAXRoleAttribute) ?? "AXUnknown"
            let texts = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                .compactMap { string(node, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let isFocused = focused.map { CFEqual($0, node) } ?? false
            let isEmptyContainer = texts.isEmpty && structuralRoles.contains(role) && !isFocused

            var childDepth = depth
            if !isEmptyContainer {
                let label = Array(NSOrderedSet(array: texts)).compactMap { $0 as? String }
                    .map { "\"\($0.prefix(maxValueChars).replacingOccurrences(of: "\n", with: " "))\"" }
                    .joined(separator: " ")
                let line = String(repeating: "  ", count: depth)
                    + role.replacingOccurrences(of: "AX", with: "")
                    + (label.isEmpty ? "" : " \(label)")
                    + (includeFrames ? frameLabel(node) : "")
                    + (isFocused ? "  <- FOCUSED" : "")
                lines.append(line)
                outputChars += line.count
                childDepth += 1
            }

            for child in children(node) {
                walk(child, depth: childDepth)
            }
        }
    }

    private static func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, attribute as CFString, &result) == .success ? result : nil
    }

    /// Web views clamp scrolled-out elements to a 1pt sliver at the viewport edge, so those are marked offscreen.
    private static func frameLabel(_ node: AXUIElement) -> String {
        guard let frame = frame(node) else { return "" }
        if frame.width <= 1 || frame.height <= 1 { return " [offscreen]" }
        return " [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = value(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func string(_ node: AXUIElement, _ attribute: String) -> String? {
        value(node, attribute) as? String
    }

    static func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let result = value(node, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
