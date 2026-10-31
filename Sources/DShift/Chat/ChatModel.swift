import AppKit

@MainActor
final class ChatModel: ObservableObject {
    private static let maxAgentIterations = 12
    private static let systemPrompt = """
        You are a sidebar assistant on the user's Mac. Each user message starts with a <context> line naming the app and \
        window the user is looking at. You don't see the window's contents until you ask for them.

        Reading the screen: when the question is about what's on screen ("this", "here", "explain this page", anything \
        referring to the window), call read_screen first. It returns the window's accessibility tree: lines indented by \
        nesting with role plus quoted text, and "<- FOCUSED" on the focused element. Skip it for questions that don't \
        need the screen (general knowledge, memory, web, follow-ups you can already answer). Ground on-screen answers in \
        what it returned and quote exact text when useful. Call it again if the user says the screen changed. Be concise: this is a narrow sidebar, so prefer short paragraphs and lists.

        The user can attach their own screenshots or images to a message; they arrive as images before the text. \
        Treat them as what the user wants you to look at.

        Web: you can search the web (web_search) and read pages (web_fetch). Use them for anything current, \
        factual, or outside what's on screen, and cite the pages you used with their URLs. Don't search for things the \
        screen already answers.

        Explaining visually: when the user asks you to explain, teach, compare, or walk through something, show it on \
        their screen without waiting to be asked. The sidebar is narrow, so the screen is where explanations belong:
        - draw_on_screen is the default: point at the things on screen and annotate them, or draw a standalone visual \
          for general concepts. Keep it to a few large, short labels; a picture with too many words can't be read.
        - show_3d_model for physical or spatial things: machines, molecules, anatomy, flows around objects.
        - scratchpad for working through steps, math, or a plan the user may want to keep or edit.
        - make_diagram renders a small Mermaid image inside the sidebar. Use it only when the user explicitly asks for a \
          diagram in the chat.
        After drawing, keep the chat reply to a sentence or two. Never draw ASCII diagrams; the sidebar's font isn't \
        monospaced.

        Screenshots: read_screen is cheaper and usually enough. Call take_screenshot only when answering genuinely \
        depends on visual information it lacks: images, charts, canvas or design apps, visual layout or styling, or a \
        read_screen result that is empty or clearly missing the content the user is asking about.

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

    let id: UUID
    private let createdAt: Date
    @Published private(set) var title = "New chat"
    @Published private(set) var entries: [TranscriptEntry] = []
    @Published var input = ""
    @Published private(set) var attachments: [Attachment] = []
    @Published private(set) var turnStartedAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isStreamingText = false
    /// True while a tool call is streaming in or running. Its row shows its own loader, so the Thinking row hides.
    @Published private(set) var isToolActive = false
    @Published private(set) var queue: [QueuedMessage] = []
    @Published private(set) var isQueuePaused = false
    @Published private(set) var usage = ChatUsage()
    @Published var focusRequest = 0
    /// Commands that act on tabs rather than this chat (/new, /history) go to the store.
    var onStoreCommand: ((SlashCommand) -> Void)?

    let tracker: AppTracker
    let scroll = ScrollSignal()

    private let tools: ToolRegistry
    private var apiMessages: [JSON] = []
    private var runTask: Task<Void, Never>?
    /// Every tool call in flight, including hidden ones that never get a transcript row.
    private var toolCalls: [String: ToolCallEntry] = [:]
    private var callsThisTurn: [String: Int] = [:]
    private var pendingTakeover: QueuedMessage?

    init(tracker: AppTracker, restoring saved: SavedChat? = nil) {
        self.tracker = tracker
        id = saved?.id ?? UUID()
        createdAt = saved?.createdAt ?? Date()
        if let saved {
            title = saved.title
            entries = saved.entries.map { Self.transcriptEntry(from: $0, chat: saved.id) }
            apiMessages = ChatArchive.apiMessages(for: saved.id)
        }
        var available: [Tool] = [
            ReadScreenTool(tracker: tracker), ScreenshotTool(tracker: tracker), MemorySearchTool(), MemoryWriteTool(),
            DiagramTool(), ScratchpadTool(),
        ]
        if let codexPath = ComputerUseTool.locateCodex() {
            available.append(ComputerUseTool(codexPath: codexPath))
        }
        if OpenAIClient.hasKey {
            available.append(OverlayTool(tracker: tracker))
            available.append(ModelTool())
        }
        tools = ToolRegistry(tools: available)
    }

    /// Return: sends now when idle, otherwise queues behind the running turn.
    func send() {
        guard let message = takeInput() else { return }
        if handleCommand(message) { return }
        isQueuePaused = false
        if isRunning {
            queue.append(message)
        } else {
            start(message)
        }
    }

    /// Cmd+Return: skips the queue, interrupting the running turn if there is one.
    func sendNow() {
        guard let message = takeInput() else { return }
        if handleCommand(message) { return }
        takeOver(with: message)
    }

    func sendQueuedNow(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        takeOver(with: queue.remove(at: index))
    }

    func attach(_ image: NSImage) {
        guard let attachment = Attachment(image: image) else { return }
        attachments.append(attachment)
        focusRequest += 1
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Attaches a screenshot of the window the user was looking at before they clicked into the sidebar.
    /// Appshot: attaches a screenshot of the window the user was looking at, labeled with its app and title.
    func attachWindowScreenshot() async {
        let app = tracker.app
        let windowTitle = tracker.windowTitle
        let output = try? await ScreenshotTool(tracker: tracker).run(["scope": "window"])
        guard let jpeg = output?.jpeg, var attachment = Attachment(jpeg: jpeg) else {
            Log.info("appshot", "capture failed for \(app?.localizedName ?? "no app")")
            return
        }
        attachment.source = Attachment.Source(
            appName: app?.localizedName ?? "Screen", windowTitle: windowTitle, icon: app?.icon)
        attachments.append(attachment)
        focusRequest += 1
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

    private func takeInput() -> QueuedMessage? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        let message = QueuedMessage(text: text, attachments: attachments)
        input = ""
        attachments = []
        return message
    }

    private func takeOver(with message: QueuedMessage) {
        isQueuePaused = false
        guard isRunning else { return start(message) }
        pendingTakeover = message
        interrupt()
    }

    private func interrupt() {
        runTask?.cancel()
        for case .tool(let call) in entries where !call.isFinished {
            if call.status == .awaitingApproval { call.resolveApproval(false) }
            if call.accessRequest != nil { call.resolveAccess(.deny) }
            // Calls that were still streaming in never run; don't leave them spinning.
            if call.status == .preparing { call.status = .cancelled }
        }
    }

    private func start(_ message: QueuedMessage) {
        let question = message.text.isEmpty ? "What do you make of this screenshot?" : message.text
        if entries.isEmpty { title = String(question.prefix(28)) }
        entries.append(.text(TextEntry(role: .user, text: message.text, attachments: message.attachments)))
        save()
        let historyNote = message.attachments.isEmpty ? "" : "\n[\(message.attachments.count) image(s) attached]"
        ChatHistory.append(role: "user", text: question + historyNote, app: tracker.app?.localizedName, chat: id)
        isRunning = true
        turnStartedAt = Date()
        runTask = Task {
            await runTurn(question: question, attachments: message.attachments)
            isRunning = false
            isToolActive = false
            turnStartedAt = nil
            save()
            advanceQueue()
        }
    }

    private func advanceQueue() {
        if let takeover = pendingTakeover {
            pendingTakeover = nil
            start(takeover)
        } else if !isQueuePaused, !queue.isEmpty {
            start(queue.removeFirst())
        }
    }

    // MARK: - Agent loop

    private func runTurn(question: String, attachments: [Attachment]) async {
        let checkpoint = apiMessages.count
        callsThisTurn = [:]
        toolCalls = [:]
        let firstReplyIndex = entries.count
        let content = userContent(for: question)
        let imageBlocks: [JSON] = attachments.flatMap { attachment -> [JSON] in
            let image: JSON = [
                "type": "image",
                "source": [
                    "type": "base64", "media_type": "image/jpeg", "data": attachment.jpeg.base64EncodedString(),
                ],
            ]
            guard let source = attachment.source else { return [image] }
            let label =
                source.windowTitle.isEmpty ? source.appName : "\(source.appName), window \"\(source.windowTitle)\""
            return [["type": "text", "text": "Appshot of \(label):"], image]
        }
        apiMessages.append(["role": "user", "content": imageBlocks + [["type": "text", "text": content]]])

        do {
            for _ in 0..<Self.maxAgentIterations {
                let message = try await streamAssistantMessage()
                apiMessages.append(["role": "assistant", "content": message.blocks])
                usage.record(message.usage)

                switch message.stopReason {
                case "tool_use":
                    apiMessages.append(["role": "user", "content": await runTools(in: message)])
                    isToolActive = false
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
            keepInterruptedTurn(
                since: checkpoint, userContent: imageBlocks + [["type": "text", "text": content]],
                firstReplyIndex: firstReplyIndex)
        } catch  where Task.isCancelled {
            keepInterruptedTurn(
                since: checkpoint, userContent: imageBlocks + [["type": "text", "text": content]],
                firstReplyIndex: firstReplyIndex)
        } catch {
            // Roll back to before this turn so the transcript never holds a tool_use without its result.
            apiMessages.removeSubrange(checkpoint...)
            appendNote("**Error:** \(error.localizedDescription)")
        }
    }

    /// After a stop or takeover, keep the question and whatever was said so far as plain text, so the next message
    /// has context. Tool calls from the interrupted turn are dropped to keep the transcript valid.
    private func keepInterruptedTurn(since checkpoint: Int, userContent: [JSON], firstReplyIndex: Int) {
        let partialReply = entries.dropFirst(firstReplyIndex)
            .compactMap { if case .text(let entry) = $0, entry.role == .assistant { entry.text } else { nil } }
            .joined(separator: "\n\n")
        apiMessages.removeSubrange(checkpoint...)
        apiMessages.append(["role": "user", "content": userContent])
        apiMessages.append([
            "role": "assistant",
            "content": [
                [
                    "type": "text",
                    "text": partialReply.isEmpty
                        ? "(Interrupted by the user before answering.)"
                        : partialReply + "\n\n(Interrupted by the user.)",
                ]
            ],
        ])
        appendNote("Stopped.")
    }

    private func streamAssistantMessage() async throws -> AssistantMessage {
        defer { isStreamingText = false }

        var message = AssistantMessage()
        var textEntries: [Int: TextEntry] = [:]
        var toolEntries: [Int: ToolCallEntry] = [:]
        defer { textEntries.values.forEach { $0.flush() } }

        Self.repairDanglingToolUses(&apiMessages)
        var serverCalls: [String: ToolCallEntry] = [:]
        for try await event in ClaudeClient.stream(
            system: Self.systemPrompt, messages: apiMessages, tools: tools.definitions + Self.serverTools)
        {
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
                    isToolActive = true
                    let entry = ToolCallEntry(
                        toolUseID: block["id"] as? String ?? "", name: block["name"] as? String ?? "tool")
                    toolEntries[index] = entry
                    toolCalls[entry.toolUseID] = entry
                    if (try? tools.tool(named: entry.name))?.isHidden != true {
                        entries.append(.tool(entry))
                    }
                // Dynamic filtering also emits internal code_execution calls; only search and fetch get a row.
                case "server_tool_use" where ["web_search", "web_fetch"].contains(block["name"] as? String ?? ""):
                    // Web search and fetch run on Anthropic's side; the row only mirrors their progress.
                    let entry = ToolCallEntry(
                        toolUseID: block["id"] as? String ?? "", name: block["name"] as? String ?? "web")
                    toolEntries[index] = entry
                    serverCalls[entry.toolUseID] = entry
                    entries.append(.tool(entry))
                case "web_search_tool_result", "web_fetch_tool_result":
                    if let entry = serverCalls[block["tool_use_id"] as? String ?? ""] {
                        Self.finishServerCall(entry, result: block)
                        scroll.tick += 1
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
                    if serverCalls[entry.toolUseID] != nil, !entry.isFinished { entry.status = .running }
                }
            case .stopReason, .usage:
                break
            }
        }

        if let reply = textEntries.sorted(by: { $0.key < $1.key }).map({ $0.value }).last {
            reply.flush()
            ChatHistory.append(role: "assistant", text: reply.text, app: tracker.app?.localizedName, chat: id)
        }
        // A cancelled stream can end without throwing. Treat it as cancelled, never as a finished reply: a
        // half-streamed tool_use saved as a normal turn breaks every later request with a 400.
        try Task.checkCancellation()
        guard !message.blocks.isEmpty else { throw ClaudeError.stream("Empty response") }
        message.dropEmptyTextBlocks()
        return message
    }

    private func runTools(in message: AssistantMessage) async -> [JSON] {
        var results: [JSON] = []
        for block in message.blocks where block["type"] as? String == "tool_use" {
            let id = block["id"] as? String ?? ""
            let entry =
                toolCalls.removeValue(forKey: id)
                ?? ToolCallEntry(toolUseID: id, name: block["name"] as? String ?? "tool")
            let (output, isError) = await execute(
                block, entry: entry, inputIsValid: !message.invalidToolInputs.contains(id))
            var content: [JSON] = [["type": "text", "text": output.text]]
            if let jpeg = output.jpeg {
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
                ])
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

            if tool.requiresApproval(for: input), !AutoMode.isOn, !(await entry.requestApproval()) {
                entry.status = .denied
                return (ToolOutput(text: "The user declined this action."), true)
            }
            entry.status = .running
            // Its own task so the row's Stop button can cancel just this tool and let Claude carry on.
            let work = Task {
                try await tool.run(
                    input,
                    progress: { [weak self] progress in
                        entry.output = progress
                        self?.scroll.tick += 1
                    },
                    requestAccess: { [weak self] app in
                        if AutoMode.isOn {
                            Log.info("auto", "allowed \(app) for this task")
                            return .once
                        }
                        self?.scroll.tick += 1
                        return await entry.requestAccess(app: app)
                    })
            }
            entry.onCancel = {
                work.cancel()
                if entry.accessRequest != nil { entry.resolveAccess(.deny) }
            }
            defer { entry.onCancel = nil }
            let output = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            Log.info("tool", "\(entry.name) ok: \(output.text.prefix(300))")
            entry.output = output.text
            entry.image = output.jpeg.flatMap(NSImage.init(data:))
            entry.status = .succeeded
            scroll.tick += 1
            return (output, false)
        } catch  where error is CancellationError || entry.isCancelRequested {
            Log.info("tool", "\(entry.name) cancelled")
            entry.output = "Cancelled."
            entry.status = .cancelled
            scroll.tick += 1
            return (ToolOutput(text: "The user cancelled this before it finished. Don't retry unless they ask."), true)
        } catch {
            Log.info("tool", "\(entry.name) failed: \(error.localizedDescription)")
            entry.output = error.localizedDescription
            entry.status = .failed
            scroll.tick += 1
            return (ToolOutput(text: error.localizedDescription), true)
        }
    }

    /// Anthropic-hosted tools: Claude searches and reads the web without any client code running.
    /// Web fetch can only open URLs that already appear in the conversation (from search results or the user).
    static let serverTools: [JSON] = [
        ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
        ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5, "max_content_tokens": 20000],
    ]

    /// Errors come back as a 200 with an error object as `content`; successful search content is a list.
    private static func finishServerCall(_ entry: ToolCallEntry, result: JSON) {
        if let error = result["content"] as? JSON, let code = error["error_code"] as? String {
            entry.output = "Error: \(code)"
            entry.status = .failed
            Log.info("web", "\(entry.name) failed: \(code)")
            return
        }
        if let results = result["content"] as? [JSON] {
            entry.output = results.compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                return "\(item["title"] as? String ?? url)\n  \(url)"
            }.joined(separator: "\n")
        } else if let fetched = result["content"] as? JSON {
            let document = fetched["content"] as? JSON
            entry.output = [(document?["title"] as? String), fetched["url"] as? String].compactMap { $0 }.joined(
                separator: "\n")
        }
        entry.status = .succeeded
        Log.info("web", "\(entry.name) ok: \(entry.inputSummary)")
    }

    /// Every tool_use must be answered by a tool_result in the next message. Fills in any that are missing
    /// (from an interrupted turn or an older saved chat) so one bad turn can't wedge the whole conversation.
    static func repairDanglingToolUses(_ messages: inout [JSON]) {
        var index = 0
        while index < messages.count {
            defer { index += 1 }
            guard messages[index]["role"] as? String == "assistant" else { continue }
            let toolUseIDs = (messages[index]["content"] as? [JSON] ?? [])
                .filter { $0["type"] as? String == "tool_use" }
                .compactMap { $0["id"] as? String }
            guard !toolUseIDs.isEmpty else { continue }

            let next = index + 1 < messages.count ? messages[index + 1] : nil
            var nextContent = next?["role"] as? String == "user" ? next?["content"] as? [JSON] ?? [] : []
            let answered = Set(
                nextContent.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil })
            let missing = toolUseIDs.filter { !answered.contains($0) }
            guard !missing.isEmpty else { continue }

            let filler: [JSON] = missing.map {
                ["type": "tool_result", "tool_use_id": $0, "content": "Cancelled before it ran.", "is_error": true]
            }
            if next?["role"] as? String == "user" {
                // tool_results must come first in the user message.
                nextContent = filler + nextContent
                messages[index + 1]["content"] = nextContent
            } else {
                messages.insert(["role": "user", "content": filler], at: index + 1)
            }
        }
    }

    // MARK: - Context

    /// Only names the app and window. The contents are read on demand with read_screen, like screenshots,
    /// so questions that don't need the screen don't pay for it.
    private func userContent(for question: String) -> String {
        let app = tracker.app?.localizedName ?? "none"
        return [
            "<context app=\"\(app)\" window=\"\(tracker.windowTitle)\" />",
            "<memory>\n\(Memory.overview())\n</memory>",
            question,
        ].joined(separator: "\n\n")
    }

    private func appendNote(_ text: String) {
        entries.append(.text(TextEntry(role: .assistant, text: "_\(text)_")))
    }

    /// Runs a bare `/command`. Returns false for ordinary messages, which are sent to Claude.
    private func handleCommand(_ message: QueuedMessage) -> Bool {
        guard message.attachments.isEmpty, message.text.hasPrefix("/") else { return false }
        guard let command = SlashCommand.exact(message.text) else {
            appendNote("Unknown command \(message.text). Type /help for the list.")
            return true
        }
        switch command {
        case .clear:
            clear()
        case .auto:
            AutoMode.isOn.toggle()
            autoModeChanged += 1
            appendNote(
                AutoMode.isOn
                    ? "Auto mode on: computer use runs without asking. Shift+Tab or /auto to turn it off."
                    : "Auto mode off: computer use asks first.")
        case .copy:
            let lastReply = entries.reversed().lazy.compactMap { entry -> String? in
                if case .text(let text) = entry, text.role == .assistant, !text.text.hasPrefix("_") { return text.text }
                return nil
            }.first
            if let lastReply {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lastReply, forType: .string)
            }
            appendNote(lastReply == nil ? "Nothing to copy yet." : "Copied the last reply.")
        case .memory:
            NSWorkspace.shared.open(Storage.memoryDir)
        case .help:
            appendNote(SlashCommand.allCases.map { "\($0.name): \($0.summary)" }.joined(separator: "\n"))
        case .new, .history:
            onStoreCommand?(command)
        }
        return true
    }

    func toggleAutoMode() {
        AutoMode.isOn.toggle()
        autoModeChanged += 1
    }

    /// Bumped when auto mode flips so views re-read it.
    @Published private(set) var autoModeChanged = 0

    private func clear() {
        queue = []
        pendingTakeover = nil
        isQueuePaused = false
        interrupt()
        entries = []
        attachments = []
        apiMessages = []
        usage = ChatUsage()
        title = "New chat"
        ChatArchive.delete(id)
    }

    // MARK: - Persistence

    private func save() {
        guard !entries.isEmpty else { return }
        var savedEntries: [SavedChat.Entry] = []
        var allAttachments: [Attachment] = []
        for entry in entries {
            switch entry {
            case .text(let text):
                allAttachments += text.attachments
                savedEntries.append(
                    SavedChat.Entry(
                        kind: text.role == .user ? .user : .assistant,
                        text: text.text,
                        attachmentIDs: text.attachments.map(\.id)
                    ))
            case .tool(let call):
                savedEntries.append(
                    SavedChat.Entry(
                        kind: .tool,
                        text: call.output,
                        toolName: call.name,
                        toolInput: call.inputSummary,
                        toolFailed: [.failed, .denied, .cancelled].contains(call.status)
                    ))
            }
        }
        let chat = SavedChat(
            id: id, title: title, createdAt: createdAt, updatedAt: Date(),
            app: tracker.app?.localizedName, entries: savedEntries
        )
        ChatArchive.save(chat, apiMessages: apiMessages, attachments: allAttachments)
    }

    private static func transcriptEntry(from saved: SavedChat.Entry, chat: UUID) -> TranscriptEntry {
        switch saved.kind {
        case .user, .assistant:
            let attachments = saved.attachmentIDs.compactMap { ChatArchive.attachment($0, in: chat) }
            return .text(
                TextEntry(role: saved.kind == .user ? .user : .assistant, text: saved.text, attachments: attachments))
        case .tool:
            let call = ToolCallEntry(toolUseID: "", name: saved.toolName ?? "tool")
            let inputData = Data((saved.toolInput ?? "").utf8)
            call.input = (try? JSONSerialization.jsonObject(with: inputData)) as? JSON ?? [:]
            call.output = saved.text
            call.status = saved.toolFailed == true ? .failed : .succeeded
            return .tool(call)
        }
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
