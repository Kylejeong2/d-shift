import AppKit

@MainActor
final class ChatModel: ObservableObject {
    private static let maxAgentIterations = 12
    private static let systemPrompt = """
    You are a sidebar assistant on the user's Mac. Each user message may include a <screen> block: a snapshot of the \
    accessibility tree of the app window the user is looking at. Lines are indented by nesting and show role plus \
    quoted text; "<- FOCUSED" marks the focused element.

    Answer questions about what is on screen and help with the task at hand. Ground answers in the snapshot and quote \
    exact text from it when useful. Be concise: this is a narrow sidebar, so prefer short paragraphs and lists.

    Screenshots: the snapshot is your primary view and is usually enough. Call take_screenshot only when answering \
    genuinely depends on visual information the snapshot lacks: images, charts, canvas or design apps, visual layout \
    or styling, or a snapshot that is empty or clearly missing the content the user is asking about. Never take one \
    to double-check text you can already read. If read_screen can refresh stale text, prefer it.

    Acting on the computer: when the user asks you to do something in their apps (send a message, fill in a form, \
    navigate somewhere, organize files) and use_computer is available, call it with one complete, self-contained \
    task. It runs in the background through Codex, which can't see this conversation, so include every detail it \
    needs: app names, exact text, recipients, and when to stop. The user approves each task first. Never use it just \
    to look at the screen, and report its result plainly, including anything it couldn't do.

    Memory: you have a persistent memory of the user, a folder of markdown files. The <memory> block holds me.md \
    (their profile) and the list of files. Treat it as your own background knowledge:
    - Before answering anything that may depend on the user's people, projects, preferences, or history, search it \
      with search_memory (for example `rg -n -i "acme" .`).
    - When you learn something durable about the user (who they work with, what they're working on, how they like \
      things written, stable preferences), save it with write_memory without asking. Put people in \
      people/<name>.md, projects in projects/<name>.md, the user's own profile in me.md, and small facts in notes.md. \
      Update existing files rather than duplicating.
    - Don't save transient details, secrets, or anything the user asks you not to keep.
    - Use memory silently. Don't announce searches or saves, and don't mention memory unless the user asks about it.
    """

    let id = UUID()
    @Published private(set) var title = "New chat"
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published var input = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isStreamingText = false
    @Published private(set) var queue: [QueuedMessage] = []
    @Published private(set) var isQueuePaused = false
    @Published private(set) var usage = ChatUsage()
    @Published var focusRequest = 0

    let tracker: AppTracker
    let scroll = ScrollSignal()

    private let tools: ToolRegistry
    private var apiMessages: [JSON] = []
    private var lastSentContext: ScreenContext?
    private var runTask: Task<Void, Never>?
    /// Every tool call in flight, including hidden ones that never get a transcript row.
    private var toolCalls: [String: ToolCallEntry] = [:]
    private var callsThisTurn: [String: Int] = [:]
    private var pendingTakeover: String?

    init(tracker: AppTracker) {
        self.tracker = tracker
        var available: [Tool] = [ReadScreenTool(tracker: tracker), ScreenshotTool(tracker: tracker), MemorySearchTool(), MemoryWriteTool()]
        if let codexPath = ComputerUseTool.locateCodex() {
            available.append(ComputerUseTool(codexPath: codexPath))
        }
        tools = ToolRegistry(tools: available)
    }

    /// Return: sends now when idle, otherwise queues behind the running turn.
    func send() {
        guard let question = takeInput() else { return }
        if question == "/clear" { return clear() }
        isQueuePaused = false
        if isRunning {
            queue.append(QueuedMessage(text: question))
        } else {
            start(question)
        }
    }

    /// Cmd+Return: skips the queue, interrupting the running turn if there is one.
    func sendNow() {
        guard let question = takeInput() else { return }
        if question == "/clear" { return clear() }
        takeOver(with: question)
    }

    func sendQueuedNow(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        takeOver(with: queue.remove(at: index).text)
    }

    func removeQueued(_ id: UUID) {
        queue.removeAll { $0.id == id }
    }

    func resumeQueue() {
        isQueuePaused = false
        if !isRunning { advanceQueue() }
    }

    /// Stops the running turn. Queued messages stay but pause until the user sends or resumes.
    func stop() {
        if !queue.isEmpty { isQueuePaused = true }
        interrupt()
    }

    private func takeInput() -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        input = ""
        return text
    }

    private func takeOver(with question: String) {
        isQueuePaused = false
        guard isRunning else { return start(question) }
        pendingTakeover = question
        interrupt()
    }

    private func interrupt() {
        runTask?.cancel()
        for case .tool(let call) in entries where call.status == .awaitingApproval {
            call.resolveApproval(false)
        }
    }

    private func start(_ question: String) {
        if entries.isEmpty { title = String(question.prefix(28)) }
        entries.append(.text(TextEntry(role: .user, text: question)))
        ChatHistory.append(role: "user", text: question, app: tracker.app?.localizedName, chat: id)
        isRunning = true
        runTask = Task {
            await runTurn(question: question)
            isRunning = false
            advanceQueue()
        }
    }

    private func advanceQueue() {
        if let takeover = pendingTakeover {
            pendingTakeover = nil
            start(takeover)
        } else if !isQueuePaused, !queue.isEmpty {
            start(queue.removeFirst().text)
        }
    }

    // MARK: - Agent loop

    private func runTurn(question: String) async {
        let checkpoint = apiMessages.count
        callsThisTurn = [:]
        toolCalls = [:]
        let firstReplyIndex = entries.count
        let context = await captureScreen()
        let content = userContent(for: question, context: context)
        apiMessages.append(["role": "user", "content": [["type": "text", "text": content]]])

        do {
            for _ in 0..<Self.maxAgentIterations {
                let message = try await streamAssistantMessage()
                apiMessages.append(["role": "assistant", "content": message.blocks])
                usage.record(message.usage)

                switch message.stopReason {
                case "tool_use":
                    apiMessages.append(["role": "user", "content": await runTools(in: message)])
                case "pause_turn":
                    continue
                case "refusal":
                    return appendNote("Claude declined to answer this request.")
                case "max_tokens":
                    return appendNote("Response hit the length limit.")
                default:
                    return
                }
            }
            appendNote("Stopped after \(Self.maxAgentIterations) steps.")
        } catch is CancellationError {
            keepInterruptedTurn(since: checkpoint, userContent: content, firstReplyIndex: firstReplyIndex)
        } catch where Task.isCancelled {
            keepInterruptedTurn(since: checkpoint, userContent: content, firstReplyIndex: firstReplyIndex)
        } catch {
            // Roll back to before this turn so the transcript never holds a tool_use without its result.
            apiMessages.removeSubrange(checkpoint...)
            lastSentContext = nil
            appendNote("**Error:** \(error.localizedDescription)")
        }
    }

    /// After a stop or takeover, keep the question and whatever was said so far as plain text, so the next message
    /// has context. Tool calls from the interrupted turn are dropped to keep the transcript valid.
    private func keepInterruptedTurn(since checkpoint: Int, userContent: String, firstReplyIndex: Int) {
        let partialReply = entries.dropFirst(firstReplyIndex)
            .compactMap { if case .text(let entry) = $0, entry.role == .assistant { entry.text } else { nil } }
            .joined(separator: "\n\n")
        apiMessages.removeSubrange(checkpoint...)
        apiMessages.append(["role": "user", "content": [["type": "text", "text": userContent]]])
        apiMessages.append(["role": "assistant", "content": [["type": "text", "text": partialReply.isEmpty
            ? "(Interrupted by the user before answering.)"
            : partialReply + "\n\n(Interrupted by the user.)"]]])
        appendNote("Stopped.")
    }

    private func streamAssistantMessage() async throws -> AssistantMessage {
        defer { isStreamingText = false }

        var message = AssistantMessage()
        var textEntries: [Int: TextEntry] = [:]
        var toolEntries: [Int: ToolCallEntry] = [:]
        defer { textEntries.values.forEach { $0.flush() } }

        for try await event in ClaudeClient.stream(system: Self.systemPrompt, messages: apiMessages, tools: tools.definitions) {
            message.apply(event)
            switch event {
            case .blockStart(let index, let block):
                switch block["type"] as? String {
                case "text":
                    let entry = TextEntry(role: .assistant, scroll: scroll)
                    textEntries[index] = entry
                    entries.append(.text(entry))
                    isStreamingText = true
                case "tool_use":
                    let entry = ToolCallEntry(toolUseID: block["id"] as? String ?? "", name: block["name"] as? String ?? "tool")
                    toolEntries[index] = entry
                    toolCalls[entry.toolUseID] = entry
                    if (try? tools.tool(named: entry.name))?.isHidden != true {
                        entries.append(.tool(entry))
                    }
                default:
                    break
                }
            case .blockDelta(let index, let delta):
                if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    textEntries[index]?.enqueue(text)
                }
            case .blockStop(let index):
                if let entry = toolEntries[index] {
                    entry.input = message.blocks[index]["input"] as? JSON ?? [:]
                }
            case .stopReason, .usage:
                break
            }
        }

        if let reply = textEntries.sorted(by: { $0.key < $1.key }).map({ $0.value }).last {
            reply.flush()
            ChatHistory.append(role: "assistant", text: reply.text, app: tracker.app?.localizedName, chat: id)
        }
        guard !message.blocks.isEmpty else { throw ClaudeError.stream("Empty response") }
        message.dropEmptyTextBlocks()
        return message
    }

    private func runTools(in message: AssistantMessage) async -> [JSON] {
        var results: [JSON] = []
        for block in message.blocks where block["type"] as? String == "tool_use" {
            let id = block["id"] as? String ?? ""
            let entry = toolCalls.removeValue(forKey: id) ?? ToolCallEntry(toolUseID: id, name: block["name"] as? String ?? "tool")
            let (output, isError) = await execute(block, entry: entry, inputIsValid: !message.invalidToolInputs.contains(id))
            var content: [JSON] = [["type": "text", "text": output.text]]
            if let jpeg = output.jpeg {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
            }
            results.append(["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError])
        }
        return results
    }

    private func execute(_ block: JSON, entry: ToolCallEntry, inputIsValid: Bool) async -> (ToolOutput, Bool) {
        do {
            guard inputIsValid else { throw ToolError.invalidInput("arguments were not valid JSON") }
            let tool = try tools.tool(named: entry.name)
            let input = block["input"] as? JSON ?? [:]
            try tools.validate(input, for: tool)
            callsThisTurn[tool.name, default: 0] += 1
            if let limit = tool.maxCallsPerTurn, callsThisTurn[tool.name, default: 0] > limit {
                throw ToolError.limitReached(tool.name, limit)
            }

            if tool.requiresApproval(for: input), !(await entry.requestApproval()) {
                entry.status = .denied
                return (ToolOutput(text: "The user declined this action."), true)
            }
            entry.status = .running
            let output = try await tool.run(input) { [weak self] progress in
                entry.output = progress
                self?.scroll.tick += 1
            }
            entry.output = output.text
            entry.image = output.jpeg.flatMap(NSImage.init(data:))
            entry.status = .succeeded
            scroll.tick += 1
            return (output, false)
        } catch {
            entry.output = error.localizedDescription
            entry.status = .failed
            scroll.tick += 1
            return (ToolOutput(text: error.localizedDescription), true)
        }
    }

    // MARK: - Context

    private func captureScreen() async -> ScreenContext? {
        guard let app = tracker.app else { return nil }
        return await Task.detached { AXSnapshot.capture(app: app) }.value
    }

    /// Only resends the screen snapshot when it changed, so follow-up questions stay cheap and cacheable.
    private func userContent(for question: String, context: ScreenContext?) -> String {
        var parts: [String] = []
        if let context, context != lastSentContext {
            parts.append("<screen app=\"\(context.appName)\" window=\"\(context.windowTitle)\">\n\(context.tree)\n</screen>")
            lastSentContext = context
        }
        parts.append("<memory>\n\(Memory.overview())\n</memory>")
        parts.append(question)
        return parts.joined(separator: "\n\n")
    }

    private func appendNote(_ text: String) {
        entries.append(.text(TextEntry(role: .assistant, text: "_\(text)_")))
    }

    private func clear() {
        queue = []
        pendingTakeover = nil
        isQueuePaused = false
        interrupt()
        entries = []
        apiMessages = []
        lastSentContext = nil
        usage = ChatUsage()
    }
}

/// Accumulates streamed content blocks verbatim, including thinking signatures, so they can be sent back unchanged.
private struct AssistantMessage {
    private(set) var blocks: [JSON] = []
    private(set) var stopReason = "end_turn"
    private(set) var usage = TokenUsage()
    private(set) var invalidToolInputs: Set<String> = []
    private var partialInputs: [Int: String] = [:]

    mutating func apply(_ event: StreamEvent) {
        switch event {
        case .blockStart(let index, let block):
            while blocks.count <= index { blocks.append([:]) }
            blocks[index] = block
        case .blockDelta(let index, let delta):
            guard blocks.indices.contains(index) else { return }
            switch delta["type"] as? String {
            case "text_delta": append(delta["text"], to: "text", at: index)
            case "thinking_delta": append(delta["thinking"], to: "thinking", at: index)
            case "signature_delta": append(delta["signature"], to: "signature", at: index)
            case "input_json_delta": partialInputs[index, default: ""] += delta["partial_json"] as? String ?? ""
            default: break
            }
        case .blockStop(let index):
            guard let raw = partialInputs.removeValue(forKey: index), blocks.indices.contains(index) else { return }
            if raw.isEmpty { return }
            if let input = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? JSON {
                blocks[index]["input"] = input
            } else {
                blocks[index]["input"] = JSON()
                invalidToolInputs.insert(blocks[index]["id"] as? String ?? "")
            }
        case .stopReason(let reason):
            stopReason = reason
        case .usage(let fields):
            usage.merge(fields)
        }
    }

    /// The API rejects empty text blocks when they are sent back in history.
    mutating func dropEmptyTextBlocks() {
        blocks.removeAll { $0["type"] as? String == "text" && ($0["text"] as? String ?? "").isEmpty }
    }

    private mutating func append(_ value: Any?, to key: String, at index: Int) {
        blocks[index][key] = (blocks[index][key] as? String ?? "") + (value as? String ?? "")
    }
}
