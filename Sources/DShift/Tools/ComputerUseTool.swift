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
        screen. Codex refuses terminal apps (Ghostty, Terminal, iTerm) for safety, so don't use it for those; tell the \
        user how to do it instead. Returns Codex's summary of what it did.
        """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "task": ["type": "string", "description": "The full task, with every detail needed and when to stop."]
        ],
        "required": ["task"],
        "additionalProperties": false,
    ]
    let maxCallsPerTurn: Int? = 3

    func requiresApproval(for input: JSON) -> Bool { true }

    func run(_ input: JSON) async throws -> ToolOutput {
        try await run(input, progress: { _ in }, requestAccess: { _ in .deny })
    }

    func run(
        _ input: JSON,
        progress: @escaping (String) -> Void,
        requestAccess: @escaping (String) async -> AppAccess
    ) async throws -> ToolOutput {
        let task = input["task"] as? String ?? ""
        let result = try await CodexRunner.run(
            task: task, codexPath: codexPath, progress: progress, requestAccess: requestAccess)
        return ToolOutput(text: result)
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

/// Drives one Codex turn over `codex app-server` (newline-delimited JSON-RPC on stdio).
///
/// Not `codex exec`: Codex Computer Use asks "Allow Computer Use to use <app>?" through an MCP elicitation before
/// touching each app, and `exec` has no client to answer it, so every app not already approved "always" was
/// silently declined. App-server forwards the elicitation here, and the sidebar asks the user.
@MainActor
enum CodexRunner {
    private static let timeout: TimeInterval = 600

    static func run(
        task: String,
        codexPath: String,
        progress: @escaping (String) -> Void,
        requestAccess: @escaping (String) async -> AppAccess
    ) async throws -> String {
        let workDir = Config.dataDir.appendingPathComponent("codex", isDirectory: true)
        let runsDir = workDir.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        let stamp = Date().ISO8601Format()
        let eventsURL = runsDir.appendingPathComponent("\(stamp).jsonl")
        let stderrURL = runsDir.appendingPathComponent("\(stamp).stderr.log")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let events = try FileHandle(forWritingTo: eventsURL)
        defer { try? events.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = workDir
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: stderrURL)

        var nextID = 0
        func send(_ message: JSON) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(0x0A)
            events.write(Data("> ".utf8) + data)
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        func request(_ method: String, _ params: JSON) -> Int {
            nextID += 1
            send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
            return nextID
        }

        Log.info("codex", "start app-server \(codexPath) events=\(eventsURL.path)")
        Log.info("codex", "task: \(task)")
        try process.run()
        let killer = DispatchWorkItem { CodexProcessTree.shutDown(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        CodexProcessTree.track(process)
        defer {
            killer.cancel()
            CodexProcessTree.shutDown(process)
        }

        return try await withTaskCancellationHandler {
            var log = CodexEventLog()
            let initializeID = request(
                "initialize",
                [
                    "clientInfo": ["name": "dshift", "title": "D-Shift", "version": "1"],
                    "capabilities": NSNull(),
                ])
            var threadStartID = -1

            for try await line in stdout.fileHandleForReading.bytes.lines {
                events.write(Data((line + "\n").utf8))
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else {
                    continue
                }
                let method = message["method"] as? String
                let id = message["id"]

                if let error = message["error"] as? JSON {
                    throw ToolError.failed("Codex app-server error: \(error["message"] as? String ?? "\(error)")")
                }
                if let method, let id {
                    // A request from the server: answer it or Codex waits forever.
                    let params = message["params"] as? JSON ?? [:]
                    send([
                        "jsonrpc": "2.0", "id": id,
                        "result": await answer(method, params, log: &log, requestAccess: requestAccess),
                    ])
                    progress(log.progressText)
                    continue
                }
                if let id = id as? Int, let result = message["result"] as? JSON {
                    if id == initializeID {
                        send(["jsonrpc": "2.0", "method": "initialized"])
                        threadStartID = request(
                            "thread/start",
                            [
                                "cwd": workDir.path,
                                // read-only: Codex can't run shell commands that write. Computer use goes through its own service.
                                "sandbox": "read-only",
                                "approvalPolicy": "on-request",
                                "ephemeral": true,
                                "developerInstructions": prompt,
                            ])
                    } else if id == threadStartID, let threadID = (result["thread"] as? JSON)?["id"] as? String {
                        _ = request(
                            "turn/start",
                            [
                                "threadId": threadID,
                                "input": [["type": "text", "text": task, "text_elements": [Any]()]],
                            ])
                    }
                    continue
                }
                guard let method else { continue }
                if log.apply(method: method, params: message["params"] as? JSON ?? [:]) {
                    Log.info("codex", log.steps.last ?? "")
                    progress(log.progressText)
                }
                if log.isDone { break }
            }

            Log.info(
                "codex",
                "done failure=\(log.failure ?? "none") blocked=\(log.blockedApps) final=\(log.finalMessage?.prefix(300) ?? "none")"
            )
            if let failure = log.failure { throw ToolError.failed("Codex failed: \(failure)") }
            if let message = log.finalMessage { return log.withBlockedNote(message) }
            if Task.isCancelled { throw CancellationError() }
            let stderrTail = (try? String(contentsOf: stderrURL, encoding: .utf8))?.suffix(800) ?? ""
            throw ToolError.failed("Codex stopped without a result (timeout after \(Int(timeout))s?). \(stderrTail)")
        } onCancel: {
            CodexProcessTree.shutDown(process)
        }
    }

    /// Answers server-to-client requests. App permission prompts go to the user; anything else that wants to run
    /// commands or edit files is declined, since D-Shift only uses Codex for computer use.
    private static func answer(
        _ method: String,
        _ params: JSON,
        log: inout CodexEventLog,
        requestAccess: (String) async -> AppAccess
    ) async -> JSON {
        guard method == "mcpServer/elicitation/request" else {
            Log.info("codex", "declined server request \(method)")
            return ["decision": "decline"]
        }
        let message = params["message"] as? String ?? ""
        let app = CodexEventLog.appName(inApprovalPrompt: message) ?? message
        log.steps.append("Asking to use \(app)")
        Log.info("codex", "elicitation: \(message)")
        let decision = await requestAccess(app)
        Log.info("codex", "elicitation answered: \(decision)")
        switch decision {
        case .once:
            log.steps.append("Allowed \(app) for this task")
            return ["action": "accept", "content": NSNull(), "_meta": ["persist": "session"]]
        case .always:
            log.steps.append("Always allowed \(app)")
            return ["action": "accept", "content": NSNull(), "_meta": ["persist": "always"]]
        case .deny:
            log.steps.append("Denied \(app)")
            return ["action": "decline", "content": NSNull(), "_meta": NSNull()]
        }
    }

    private static let prompt = """
        You are operating the user's Mac on behalf of D-Shift, their sidebar assistant. Use computer use to complete \
        the task, working in the background without taking over the user's foreground app when possible. Do only what \
        the task asks. If a step is ambiguous, or would send, buy, delete, or share something beyond what the task \
        states, stop and explain instead of guessing. End with a short summary of what you did and what, if anything, \
        is left.
        """
}

/// Tears down a `codex app-server` run completely. Each run spawns about 15 processes (a login shell, the Computer
/// Use REPLs, sandboxed node kernels, MCP servers, a nested app-server), so terminating only the top process relies
/// on every child noticing. This snapshots the whole tree first, sends SIGTERM to all of it, and SIGKILLs anything
/// still alive after a grace period. It never touches the ChatGPT/Codex desktop app's own processes, which aren't
/// descendants of D-Shift's run.
enum CodexProcessTree {
    private static let gracePeriod: TimeInterval = 2
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Process] = []

    static func track(_ process: Process) {
        lock.withLock { running.append(process) }
    }

    /// Safe to call more than once and from any thread.
    static func shutDown(_ process: Process) {
        let root = process.processIdentifier
        lock.withLock { running.removeAll { $0 === process } }
        guard root > 0 else { return }
        let tree = descendants(of: root) + [root]
        let alive = tree.filter { kill($0, 0) == 0 }
        guard !alive.isEmpty else { return }
        Log.info("codex", "shutting down \(alive.count) process(es) from run \(root)")
        alive.forEach { kill($0, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) {
            let stragglers = alive.filter { kill($0, 0) == 0 }
            guard !stragglers.isEmpty else { return }
            Log.info("codex", "force-killing \(stragglers.count) process(es) that ignored SIGTERM: \(stragglers)")
            stragglers.forEach { kill($0, SIGKILL) }
        }
    }

    /// Stops every run still going, for app quit. Blocks briefly so children get SIGTERM before D-Shift exits.
    static func shutDownAll() {
        let processes = lock.withLock { running }
        processes.forEach(shutDown)
    }

    /// All descendants, deepest first, via `pgrep -P` breadth-first walk. pgrep is used rather than libproc so
    /// this has no private API dependency.
    static func descendants(of root: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            let children = childPIDs(of: parent)
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return result.reversed()
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(parent)]
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }
}

/// Folds `codex app-server` notifications into progress lines and a final result.
struct CodexEventLog {
    private static let maxProgressLines = 12

    var steps: [String] = []
    private(set) var finalMessage: String?
    private(set) var failure: String?
    private(set) var isDone = false
    /// Apps Computer Use refused, e.g. "Finder: not approved". Terminals are hard-blocked by Codex for safety.
    private(set) var blockedApps: [String] = []

    var progressText: String { steps.suffix(Self.maxProgressLines).joined(separator: "\n") }

    /// Returns true when the notification changed what should be shown.
    mutating func apply(method: String, params: JSON) -> Bool {
        let item = params["item"] as? JSON ?? [:]
        switch (method, item["type"] as? String) {
        case ("item/started", "mcpToolCall"):
            let title = (item["arguments"] as? JSON)?["title"] as? String
            steps.append(title ?? item["tool"] as? String ?? "tool")
        case ("item/completed", "mcpToolCall"):
            if let block = Self.blockReason(in: item) {
                if !blockedApps.contains(block) { blockedApps.append(block) }
                steps.append("Blocked: \(block)")
            } else if item["status"] as? String == "failed" {
                steps.append("\(item["tool"] as? String ?? "tool") failed")
            } else {
                return false
            }
        case ("item/started", "commandExecution"):
            steps.append("Running \(item["command"] as? String ?? "a command")")
        case ("item/completed", "agentMessage"):
            let text = item["text"] as? String ?? ""
            if item["phase"] as? String == "final_answer" {
                finalMessage = text
                return false
            }
            guard let firstLine = text.split(separator: "\n").first else { return false }
            steps.append(String(firstLine))
        case ("turn/completed", _):
            isDone = true
            let turn = params["turn"] as? JSON ?? [:]
            if let error = turn["error"] as? JSON {
                failure = error["message"] as? String ?? "turn failed"
            }
            if finalMessage == nil {
                let messages = (turn["items"] as? [JSON] ?? []).filter { $0["type"] as? String == "agentMessage" }
                finalMessage = messages.last?["text"] as? String
            }
            return false
        case ("error", _):
            failure =
                (params["error"] as? JSON)?["message"] as? String ?? params["message"] as? String ?? "unknown error"
        default:
            return false
        }
        return true
    }

    func withBlockedNote(_ message: String) -> String {
        guard !blockedApps.isEmpty else { return message }
        return message + "\n\nComputer Use refused: " + blockedApps.joined(separator: "; ")
            + ". \"Blocked for safety\" apps (terminals) can never be controlled by Codex."
    }

    /// "Allow Computer Use to use \"Slack\"?" -> "Slack"
    static func appName(inApprovalPrompt message: String) -> String? {
        guard let open = message.firstIndex(of: "\""),
            let close = message[message.index(after: open)...].firstIndex(of: "\"")
        else {
            return nil
        }
        return String(message[message.index(after: open)..<close])
    }

    private static func blockReason(in item: JSON) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
        return blockReason(String(decoding: data, as: UTF8.self))
    }

    /// Recognizes Computer Use's refusals: "Computer Use was not approved to use Finder" and
    /// "Computer Use is not allowed to use the app 'com.mitchellh.ghostty' for safety reasons".
    static func blockReason(_ text: String) -> String? {
        if let range = text.range(of: "Computer Use was not approved to use ") {
            let app = text[range.upperBound...].prefix { !"\n.\"\\".contains($0) }
            return "\(app): not approved"
        }
        if let range = text.range(of: "is not allowed to use the app '") {
            let app = text[range.upperBound...].prefix { $0 != "'" }
            return "\(app): blocked for safety (Codex never controls this app)"
        }
        return nil
    }
}
