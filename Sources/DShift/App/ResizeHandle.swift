import AppKit

/// Invisible strip along a panel edge that resizes the window while keeping the opposite edge pinned.
/// The panel docks to the top-right, so the left edge controls width and the bottom edge controls height.
final class ResizeHandle: NSView {
    enum Edge { case left, bottom }

    private let edge: Edge
    private let onResizeEnd: (CGSize) -> Void
    private var dragStartMouse: NSPoint = .zero
    private var dragStartFrame: NSRect = .zero

    init(edge: Edge, onResizeEnd: @escaping (CGSize) -> Void) {
        self.edge = edge
        self.onResizeEnd = onResizeEnd
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: edge == .left ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        var frame = dragStartFrame
        switch edge {
        case .left:
            frame.size.width = clamp(dragStartFrame.width - (mouse.x - dragStartMouse.x), window.minSize.width, window.maxSize.width)
            frame.origin.x = dragStartFrame.maxX - frame.width
        case .bottom:
            frame.size.height = clamp(dragStartFrame.height - (mouse.y - dragStartMouse.y), window.minSize.height, window.maxSize.height)
            frame.origin.y = dragStartFrame.maxY - frame.height
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if let size = window?.frame.size { onResizeEnd(size) }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
