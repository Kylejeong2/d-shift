import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sidebar: SidebarController!
    private var shiftMonitor: DoubleShiftMonitor!
    private var appshotMonitor: ModifierChordMonitor!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            print("Grant Accessibility access (System Settings > Privacy & Security > Accessibility), then relaunch.")
        }

        sidebar = SidebarController()
        shiftMonitor = DoubleShiftMonitor { [weak self] in self?.sidebar.toggle() }
        shiftMonitor.start()
        appshotMonitor = ModifierChordMonitor { [weak self] in
            Task { await self?.sidebar.appshot() }
        }
        appshotMonitor.start()
        setUpStatusItem()
        setUpEditMenu()
    }

    /// Launching D-Shift again while it runs opens the sidebar instead of starting a second copy.
    func showSidebar() {
        sidebar?.show()
    }

    /// Accessory apps get no menu bar, and without an Edit menu Cmd+C/X/A have nothing to route to, so text
    /// selected in replies couldn't be copied. The menu is never visible; it only supplies the key equivalents.
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // Cmd+V is handled by the input bar so it can attach copied images.
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())  // app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Don't leave a Codex computer-use run behind when D-Shift quits mid-task.
    func applicationWillTerminate(_ notification: Notification) {
        CodexProcessTree.shutDownAll()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shift", accessibilityDescription: "D-Shift")
        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Sidebar (Shift Shift)", action: #selector(toggleSidebar), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Open Memory Folder", action: #selector(openMemory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Feedback Folder", action: #selector(openFeedback), keyEquivalent: "").target =
            self
        menu.addItem(withTitle: "Change API Key...", action: #selector(changeAPIKey), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set OpenAI API Key...", action: #selector(setOpenAIKey), keyEquivalent: "").target =
            self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit D-Shift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleSidebar() { sidebar.toggle() }
    @objc private func openMemory() { NSWorkspace.shared.open(Storage.memoryDir) }
    @objc private func openFeedback() { NSWorkspace.shared.open(Feedback.dir) }

    @objc private func changeAPIKey() {
        APIKeyStore.shared.reset()
        sidebar.reveal()
    }

    /// Optional key for on-screen graphics. Saved to the keychain; an empty field removes it. New chat tabs pick it up.
    @objc private func setOpenAIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText =
            "Used only for drawing on your screen (GPT-6.1 Sol Ultrafast). Open a new chat tab after saving. Leave empty to remove."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            Keychain.delete("OPENAI_API_KEY")
        } else {
            Keychain.save(key, for: "OPENAI_API_KEY")
        }
    }
}
