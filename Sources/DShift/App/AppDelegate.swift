import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sidebar: SidebarController!
    private var shiftMonitor: DoubleShiftMonitor!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            print("Grant Accessibility access (System Settings > Privacy & Security > Accessibility), then relaunch.")
        }

        sidebar = SidebarController()
        shiftMonitor = DoubleShiftMonitor { [weak self] in self?.sidebar.toggle() }
        shiftMonitor.start()
        setUpStatusItem()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shift", accessibilityDescription: "D-Shift")
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Sidebar (Shift Shift)", action: #selector(toggleSidebar), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Memory Folder", action: #selector(openMemory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit D-Shift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleSidebar() { sidebar.toggle() }
    @objc private func openMemory() { NSWorkspace.shared.open(Storage.memoryDir) }
}
