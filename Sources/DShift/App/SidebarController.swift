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
    private static let backdropOpacity: CGFloat = 0.85
    private static let widthKey = "sidebar.width"
    private static let heightKey = "sidebar.height"
    private static let topInsetKey = "sidebar.topInset"
    private static let cornerHandleSize: CGFloat = 24

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
        store.onLastChatClosed = { [weak panel] in panel?.orderOut(nil) }
        for view in [backdrop, hosting] as [NSView] {
            Self.pin(view, in: container)
        }
        // Handles sit on a root view above the rounded, clipped container so the corner handles reach into the
        // transparent rounded-off corners instead of being clipped away.
        let root = NSView()
        Self.pin(container, in: root)
        panel.contentView = root

        let handleEdges: [ResizeHandle.Edges] = [.left, .top, .bottom, [.top, .left], [.bottom, .left]]
        for edges in handleEdges {
            let handle = ResizeHandle(edges: edges) { [weak self] frame in self?.saveFrame(frame) }
            handle.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(handle)
            let thickness = Self.handleThickness
            let corner = Self.cornerHandleSize
            var constraints: [NSLayoutConstraint] = []
            if edges.contains(.left) {
                constraints.append(handle.leadingAnchor.constraint(equalTo: root.leadingAnchor))
            }
            switch edges {
            case .left:
                constraints += [
                    handle.widthAnchor.constraint(equalToConstant: thickness),
                    handle.topAnchor.constraint(equalTo: root.topAnchor, constant: corner),
                    handle.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -corner),
                ]
            case .top, .bottom:
                constraints += [
                    handle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: corner),
                    handle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                    handle.heightAnchor.constraint(equalToConstant: thickness),
                    edges == .top
                        ? handle.topAnchor.constraint(equalTo: root.topAnchor)
                        : handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                ]
            default:
                constraints += [
                    handle.widthAnchor.constraint(equalToConstant: corner),
                    handle.heightAnchor.constraint(equalToConstant: corner),
                    edges.contains(.top)
                        ? handle.topAnchor.constraint(equalTo: root.topAnchor)
                        : handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                ]
            }
            NSLayoutConstraint.activate(constraints)
        }
    }

    func toggle() {
        panel.isVisible ? panel.orderOut(nil) : show()
    }

    func reveal() {
        if !panel.isVisible { show() }
    }

    private func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let maxHeight = visible.height - Self.edgeInset * 2
            let maxWidth = visible.width - Self.edgeInset * 2
            panel.maxSize = CGSize(width: maxWidth, height: maxHeight)

            let defaults = UserDefaults.standard
            let savedWidth = defaults.double(forKey: Self.widthKey)
            let savedHeight = defaults.double(forKey: Self.heightKey)
            let width = min(max(savedWidth > 0 ? savedWidth : Self.defaultWidth, Self.minSize.width), maxWidth)
            let height = min(max(savedHeight > 0 ? savedHeight : maxHeight, Self.minSize.height), maxHeight)
            let savedTopInset = defaults.object(forKey: Self.topInsetKey) as? Double ?? Self.edgeInset
            let topInset = min(max(savedTopInset, 0), visible.height - height)
            panel.setFrame(NSRect(
                x: visible.maxX - width - Self.edgeInset,
                y: visible.maxY - topInset - height,
                width: width,
                height: height
            ), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        store.selected.focusRequest += 1
    }

    /// Remembers size and vertical position; the panel always re-docks to the right edge of the screen.
    private func saveFrame(_ frame: NSRect) {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.width), forKey: Self.widthKey)
        defaults.set(Double(frame.height), forKey: Self.heightKey)
        if let visible = panel.screen?.visibleFrame {
            defaults.set(Double(visible.maxY - frame.maxY), forKey: Self.topInsetKey)
        }
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
