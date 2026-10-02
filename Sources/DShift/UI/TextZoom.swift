import SwiftUI

/// Browser-style text zoom: Cmd+= / Cmd+- step through fixed levels, Cmd+0 resets. Persisted across launches.
enum TextZoom {
    static let storageKey = "textZoom"
    private static let levels: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    static func step(_ current: Double, by direction: Int) -> Double {
        let index = levels.firstIndex { $0 >= current - 0.001 } ?? levels.count - 1
        return levels[min(max(index + direction, 0), levels.count - 1)]
    }
}

struct TextZoomShortcuts: View {
    @AppStorage(TextZoom.storageKey) private var zoom = 1.0

    var body: some View {
        ZStack {
            ShortcutKey("=", action: { zoom = TextZoom.step(zoom, by: 1) })
            ShortcutKey("+", action: { zoom = TextZoom.step(zoom, by: 1) })
            ShortcutKey("-", action: { zoom = TextZoom.step(zoom, by: -1) })
            ShortcutKey("0", action: { zoom = 1.0 })
        }
    }
}

/// A keyboard shortcut with no visible control.
struct ShortcutKey: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    let action: () -> Void

    init(_ key: KeyEquivalent, modifiers: EventModifiers = .command, action: @escaping () -> Void) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct ScaledFont: ViewModifier {
    @AppStorage(TextZoom.storageKey) private var zoom = 1.0
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * zoom, weight: weight, design: design))
    }
}

extension View {
    /// A system font that follows the sidebar's text zoom.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}
