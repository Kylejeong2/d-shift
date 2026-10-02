import AppKit
import SwiftUI

/// Borderless, non-activating panel: it takes keyboard input without stealing frontmost status from the app being asked about.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class SidebarController {
    private static let defaultWidth: CGFloat = 400
    private static let minSize = CGSize(width: 300, height: 320)
    private static let edgeInset: CGFloat = 8
    private static let handleThickness: CGFloat = 6
    // Continuous-curve radius in line with macOS floating panels and Control Center.
    private static let cornerRadius: CGFloat = 20
    // Lower is more see-through. Only the backdrop fades; text and controls stay fully opaque.
    private static let backdropOpacity: CGFloat = 0.78
    private static let widthKey = "sidebar.width"
    private static let heightKey = "sidebar.height"

    private let store = ChatStore()
    private let panel: SidebarPanel

    init() {
        panel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = Self.minSize
        // Keep the sidebar out of screenshots and screen recordings, including its own take_screenshot tool.
        panel.sharingType = .none

        let container = NSView()
        container.wantsLayer = true
        Self.roundCorners(of: container)
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.alphaValue = Self.backdropOpacity
        backdrop.wantsLayer = true
        Self.roundCorners(of: backdrop)

        let hosting = NSHostingView(rootView: SidebarView(store: store, onClose: { [weak panel] in panel?.orderOut(nil) }))
        for view in [backdrop, hosting] as [NSView] {
            Self.pin(view, in: container)
        }
        panel.contentView = container

        let saveSize: (CGSize) -> Void = { size in
            UserDefaults.standard.set(Double(size.width), forKey: Self.widthKey)
            UserDefaults.standard.set(Double(size.height), forKey: Self.heightKey)
        }
        let leftHandle = ResizeHandle(edge: .left, onResizeEnd: saveSize)
        let bottomHandle = ResizeHandle(edge: .bottom, onResizeEnd: saveSize)
        for handle in [leftHandle, bottomHandle] {
            handle.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(handle)
        }
        NSLayoutConstraint.activate([
            leftHandle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            leftHandle.topAnchor.constraint(equalTo: container.topAnchor),
            leftHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leftHandle.widthAnchor.constraint(equalToConstant: Self.handleThickness),
            bottomHandle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomHandle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bottomHandle.heightAnchor.constraint(equalToConstant: Self.handleThickness),
        ])
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show()
    }

    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let maxHeight = visible.height - Self.edgeInset * 2
            let maxWidth = visible.width - Self.edgeInset * 2
            panel.maxSize = CGSize(width: maxWidth, height: maxHeight)

            let savedWidth = UserDefaults.standard.double(forKey: Self.widthKey)
            let savedHeight = UserDefaults.standard.double(forKey: Self.heightKey)
            let width = min(max(savedWidth > 0 ? savedWidth : Self.defaultWidth, Self.minSize.width), maxWidth)
            let height = min(max(savedHeight > 0 ? savedHeight : maxHeight, Self.minSize.height), maxHeight)
            panel.setFrame(NSRect(
                x: visible.maxX - width - Self.edgeInset,
                y: visible.maxY - height - Self.edgeInset,
                width: width,
                height: height
            ), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        store.selected.focusRequest += 1
    }

    private static func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private static func roundCorners(of view: NSView) {
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
