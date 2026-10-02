import AppKit
import ApplicationServices

struct ScreenContext: Equatable {
    let appName: String
    let windowTitle: String
    let tree: String
}

/// Serializes the focused window's accessibility tree into compact indented text for the model.
enum AXSnapshot {
    private static let maxNodesVisited = 3000
    private static let maxOutputChars = 60_000
    private static let maxValueChars = 500
    private static let maxDepth = 40
    private static let structuralRoles: Set<String> = ["AXGroup", "AXUnknown", "AXSplitGroup", "AXScrollArea", "AXLayoutArea"]

    static func capture(app: NSRunningApplication) -> ScreenContext {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Chrome and Electron only build their full tree once an assistive client asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown app"
        guard let window = element(appElement, kAXFocusedWindowAttribute) ?? element(appElement, kAXMainWindowAttribute) else {
            return ScreenContext(appName: appName, windowTitle: "", tree: "(no accessible window)")
        }

        var walker = Walker(focused: element(appElement, kAXFocusedUIElementAttribute))
        walker.walk(window, depth: 0)

        var tree = walker.lines.joined(separator: "\n")
        if walker.truncated { tree += "\n(truncated)" }
        if let focused = walker.focused, let selection = string(focused, kAXSelectedTextAttribute), !selection.isEmpty {
            tree += "\n\nSelected text:\n\(selection.prefix(maxValueChars * 4))"
        }
        return ScreenContext(appName: appName, windowTitle: string(window, kAXTitleAttribute) ?? "", tree: tree)
    }

    private struct Walker {
        let focused: AXUIElement?
        var lines: [String] = []
        var visited = 0
        var outputChars = 0
        var truncated = false

        mutating func walk(_ node: AXUIElement, depth: Int) {
            guard visited < maxNodesVisited, outputChars < maxOutputChars, depth < maxDepth else {
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
