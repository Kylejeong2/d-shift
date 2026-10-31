import AppKit

/// Claude Code-style commands typed into the chat input.
enum SlashCommand: String, CaseIterable, Identifiable {
    case auto
    case new
    case clear
    case history
    case copy
    case memory
    case help

    var id: String { rawValue }
    var name: String { "/\(rawValue)" }

    var summary: String {
        switch self {
        case .auto:
            AutoMode.isOn ? "Turn off auto mode (ask before computer use)" : "Auto mode: always allow computer use"
        case .new: "Start a new chat tab"
        case .clear: "Clear this chat"
        case .history: "Reopen a past chat"
        case .copy: "Copy the last reply"
        case .memory: "Open the memory folder"
        case .help: "List commands"
        }
    }

    /// Commands whose name starts with what's typed after the slash. Empty when the input isn't a bare command.
    static func matches(for input: String) -> [SlashCommand] {
        guard input.hasPrefix("/"), !input.contains(" "), !input.contains("\n") else { return [] }
        let typed = input.dropFirst().lowercased()
        return allCases.filter { $0.rawValue.hasPrefix(typed) }
    }

    static func exact(_ input: String) -> SlashCommand? {
        allCases.first { $0.name == input.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

/// When on, computer-use tasks run without the "Let Codex do this?" card, and Codex's per-app permission
/// questions are answered "allow for this task". Codex still refuses apps it blocks for safety (terminals).
enum AutoMode {
    static let key = "autoMode"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
