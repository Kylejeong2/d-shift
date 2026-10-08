import AppKit

/// Invisible strip or corner on the panel's edge that resizes the window, keeping the opposite edges pinned.
/// The panel docks to the right of the screen, so only the left, top, and bottom edges are draggable.
final class ResizeHandle: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let top = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
    }

    private let edges: Edges
    private let onResizeEnd: (NSRect) -> Void
    private var dragStartMouse: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    init(edges: Edges, onResizeEnd: @escaping (NSRect) -> Void) {
        self.edges = edges
        self.onResizeEnd = onResizeEnd
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Radius of the panel's rounded corners. The fill is clipped to it.
    var cornerRadius: CGFloat = 0

    // macOS passes clicks on fully transparent pixels to the window behind, so a fill too faint to see keeps the
    // handles clickable. It stays inside the rounded panel shape: any pixel past it, even at 1% alpha, makes the
    // window shadow and screenshots show square corners.
    override func draw(_ dirtyRect: NSRect) {
        if let panelBounds = superview?.bounds {
            NSBezierPath(roundedRect: convert(panelBounds, from: superview), xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        }
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Cursor rects only apply in the active app, and the panel never activates D-Shift, so track hover directly.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        cursor.set()
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartMouse.x
        let dy = mouse.y - dragStartMouse.y
        var frame = dragStartFrame

        if edges.contains(.left) {
            frame.size.width = clamp(dragStartFrame.width - dx, window.minSize.width, window.maxSize.width)
            frame.origin.x = dragStartFrame.maxX - frame.width
        }
        if edges.contains(.top) {
            let screenTop = window.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude
            let maxHeight = min(window.maxSize.height, screenTop - dragStartFrame.minY)
            frame.size.height = clamp(dragStartFrame.height + dy, window.minSize.height, maxHeight)
        }
        if edges.contains(.bottom) {
            let screenBottom = window.screen?.visibleFrame.minY ?? 0
            let maxHeight = min(window.maxSize.height, dragStartFrame.maxY - screenBottom)
            frame.size.height = clamp(dragStartFrame.height - dy, window.minSize.height, maxHeight)
            frame.origin.y = dragStartFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let frame = window?.frame { onResizeEnd(frame) }
    }

    private var cursor: NSCursor {
        switch edges {
        case .left: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default:
            if #available(macOS 15, *) {
                return .frameResize(position: edges.contains(.top) ? .topLeft : .bottomLeft, directions: .all)
            }
            return .crosshair
        }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}
