import Foundation

/// Hands a task to Codex (`codex exec`), which operates the user's apps in the background with its own
/// computer-use agent. Requires the Codex CLI with Computer Use enabled and signed in.
/// Always asks for approval: the task can click, type, and send things anywhere on the Mac.
struct ComputerUseTool: Tool {
    let codexPath: String

    let name = "use_computer"
    let description = """
    Have Codex, OpenAI's computer-use agent, operate apps on the user's Mac in the background to complete a task: \
    clicking, typing, and navigating in other apps. The agent can't see this conversation, so `task` must be \
    complete and self-contained. Use only when the user asks you to do something in their apps, not to read the \
    screen. Returns Codex's summary of what it did.
    """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "task": ["type": "string", "description": "The full task, with every detail needed and when to stop."],
        ],
        "required": ["task"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 3

    func requiresApproval(for input: JSON) -> Bool { true }

    func run(_ input: JSON) async throws -> ToolOutput {
        try await run(input) { _ in }
    }

    func run(_ input: JSON, progress: @escaping (String) -> Void) async throws -> ToolOutput {
        let task = input["task"] as? String ?? ""
        return ToolOutput(text: try await CodexRunner.run(task: task, codexPath: codexPath, progress: progress))
    }

    /// `DSHIFT_CODEX_PATH` wins; otherwise the CLI bundled with the ChatGPT app, then common install locations.
    static func locateCodex() -> String? {
        if let configured = Config.value("DSHIFT_CODEX_PATH") {
            return (configured as NSString).expandingTildeInPath
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.bun/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

@MainActor
enum CodexRunner {
    private static let timeout: TimeInterval = 600

    static func run(task: String, codexPath: String, progress: @escaping (String) -> Void) async throws -> String {
        let workDir = Config.dataDir.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let stderrURL = workDir.appendingPathComponent("last-run-stderr.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        // read-only sandbox: Codex can't run shell commands that write. Computer use goes through its own service.
        process.arguments = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                             "-C", workDir.path, prompt(for: task)]
        process.currentDirectoryURL = workDir
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        // codex exec reads extra input from stdin until EOF, so it must be closed.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        return try await withTaskCancellationHandler {
            var log = CodexEventLog()
            for try await line in stdout.fileHandleForReading.bytes.lines where log.apply(line) {
                progress(log.progressText)
            }
            process.waitUntilExit()

            if let failure = log.failure { throw ToolError.failed("Codex failed: \(failure)") }
            if let message = log.finalMessage { return message }
            if process.terminationReason == .uncaughtSignal {
                throw ToolError.failed("Codex was stopped (timeout after \(Int(timeout))s or cancelled).")
            }
            let stderrTail = (try? String(contentsOf: stderrURL, encoding: .utf8))?.suffix(800) ?? ""
            throw ToolError.failed("Codex exited with status \(process.terminationStatus) without a result. \(stderrTail)")
        } onCancel: {
            process.terminate()
        }
    }

    private static func prompt(for task: String) -> String {
        """
        You are operating the user's Mac on behalf of D-Shift, their sidebar assistant. Use computer use to complete \
        the task below, working in the background without taking over the user's foreground app when possible. Do \
        only what the task asks. If a step is ambiguous, or would send, buy, delete, or share something beyond what \
        the task states, stop and explain instead of guessing. End with a short summary of what you did and what, \
        if anything, is left.

        Task: \(task)
        """
    }
}

/// Folds the `codex exec --json` event stream into progress lines and a final result.
/// Event format: https://developers.openai.com/codex/noninteractive
struct CodexEventLog {
    private static let maxProgressLines = 12

    private(set) var steps: [String] = []
    private(set) var finalMessage: String?
    private(set) var failure: String?

    var progressText: String { steps.suffix(Self.maxProgressLines).joined(separator: "\n") }

    /// Returns true when the event changed what should be shown.
    mutating func apply(_ line: String) -> Bool {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else { return false }
        let item = event["item"] as? JSON ?? [:]

        switch (event["type"] as? String, item["type"] as? String) {
        case ("item.started", "mcp_tool_call"):
            let app = (item["arguments"] as? JSON)?["app"] as? String
            steps.append([item["tool"] as? String ?? "tool", app.map { "in \($0)" }].compactMap { $0 }.joined(separator: " "))
        case ("item.completed", "mcp_tool_call") where item["status"] as? String == "failed":
            steps.append("\(item["tool"] as? String ?? "tool") failed")
        case ("item.started", "command_execution"):
            steps.append("Running \(item["command"] as? String ?? "a command")")
        case ("item.completed", "reasoning"):
            let text = (item["text"] as? String ?? "").replacingOccurrences(of: "**", with: "")
            guard let firstLine = text.split(separator: "\n").first else { return false }
            steps.append(String(firstLine))
        case ("item.completed", "agent_message"):
            finalMessage = item["text"] as? String
            return false
        case ("turn.failed", _):
            failure = (event["error"] as? JSON)?["message"] as? String ?? "turn failed"
        case ("error", _):
            failure = event["message"] as? String ?? "unknown error"
        default:
            return false
        }
        return true
    }
}
