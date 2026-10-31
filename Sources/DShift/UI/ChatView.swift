import SwiftUI

/// Shared surface tokens: one radius for bubbles, cards, and the input; a smaller one for tabs and nested media.
enum Theme {
    static let surfaceShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let innerShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    static let surfaceFill = Color.black.opacity(0.4)
    static let stroke = Color.white.opacity(0.1)
}

struct SidebarView: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var apiKeys = APIKeyStore.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(store: store, onClose: onClose)
            if apiKeys.hasKey {
                AppContextHeader(tracker: store.tracker)
                Divider().opacity(0.25)
                ChatView(model: store.selected)
                    .id(store.selectedID)
            } else {
                APIKeySetupView(apiKeys: apiKeys)
            }
        }
        .background { TextZoomShortcuts() }
        // Clicking anywhere that isn't a control puts the cursor in the input. Child buttons and tabs win over this.
        .contentShape(Rectangle())
        .onTapGesture { store.selected.focusRequest += 1 }
    }
}

private struct APIKeySetupView: View {
    let apiKeys: APIKeyStore
    @State private var key = ""
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your Anthropic API key")
                .scaledFont(15, weight: .semibold)
            Text(
                "D-Shift sends your questions and screen context to Claude using your own key. The key is stored in your macOS Keychain."
            )
            .scaledFont(12)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-...", text: $key)
                .textFieldStyle(.plain)
                .scaledFont(13)
                .padding(10)
                .background(Theme.surfaceFill, in: Theme.surfaceShape)
                .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
                .onSubmit(save)
            if saveFailed {
                Text("Couldn't save the key to the Keychain. Try again.")
                    .scaledFont(11)
                    .foregroundStyle(.red)
            }
            HStack {
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .scaledFont(12)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .padding(16)
    }

    private func save() {
        saveFailed = !apiKeys.save(key)
        if !saveFailed { key = "" }
    }
}

private struct ChatView: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(model: model, scroll: model.scroll)
            if !model.queue.isEmpty {
                QueueView(model: model)
            }
            UsageBar(usage: model.usage)
            InputBar(model: model)
        }
    }
}

private struct TabStrip: View {
    @ObservedObject var store: ChatStore
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.chats, id: \.id) { chat in
                        TabButton(
                            chat: chat,
                            isSelected: chat.id == store.selectedID,
                            onSelect: { store.select(chat.id) },
                            onClose: { store.close(chat.id) }
                        )
                    }
                    IconButton(systemName: "plus", help: "New chat (Cmd+T)", action: store.newChat)
                        .keyboardShortcut("t", modifiers: .command)
                }
            }
            ShortcutKey("w", action: { store.close(store.selectedID) })
            HistoryButton(store: store)
            FeedbackButton(store: store)
            IconButton(systemName: "xmark", help: "Hide sidebar", action: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

private struct TabButton: View {
    @ObservedObject var chat: ChatModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if chat.isRunning {
                ProgressView().controlSize(.mini)
            }
            Text(chat.title)
                .scaledFont(11, weight: isSelected ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .leading)
            if isHovering || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .scaledFont(8, weight: .bold)
                }
                .buttonStyle(.plain)
                .help("Close chat")
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            .white.opacity(isSelected ? 0.13 : (isHovering ? 0.07 : 0)),
            in: Theme.innerShape
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(11, weight: .semibold)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct AppContextHeader: View {
    @ObservedObject var tracker: AppTracker

    var body: some View {
        HStack(spacing: 8) {
            if let icon = tracker.app?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Image(systemName: "eye")
                .scaledFont(10)
                .foregroundStyle(.secondary)
            Text(tracker.app?.localizedName ?? "No app")
                .scaledFont(12, weight: .semibold)
            if !tracker.windowTitle.isEmpty {
                Text(tracker.windowTitle)
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

private struct TranscriptView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var scroll: ScrollSignal

    /// True while the bottom of the transcript is in view. Auto-scroll only follows new output while pinned,
    /// so scrolling up to reread something isn't yanked back down.
    @State private var isPinnedToBottom = true

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.entries.isEmpty {
                            EmptyState()
                                .transition(.identity)
                        }
                        ForEach(TranscriptItem.group(model.entries)) { item in
                            Group {
                                switch item {
                                case .text(let text): TextRow(entry: text)
                                case .tools(let calls): ToolGroup(calls: calls)
                                case .task(let call): TaskRow(entry: call)
                                }
                            }
                            .transition(.fadeUp)
                        }
                        if model.isRunning && !model.isStreamingText && !model.isToolActive,
                            let startedAt = model.turnStartedAt
                        {
                            ThinkingRow(startedAt: startedAt)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background(
                                GeometryReader { marker in
                                    Color.clear.preference(
                                        key: BottomOffsetKey.self, value: marker.frame(in: .named(scrollSpace)).maxY)
                                })
                    }
                    .padding(14)
                    .animation(.fadeUp, value: model.entries.count)
                    .animation(.fadeUp, value: model.isRunning)
                }
                .coordinateSpace(name: scrollSpace)
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(BottomOffsetKey.self) { bottom in
                    isPinnedToBottom = bottom <= viewport.size.height + 40
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: scroll.tick) { if isPinnedToBottom { scrollToBottom(proxy) } }
                .onChange(of: model.isStreamingText) { if isPinnedToBottom { scrollToBottom(proxy) } }
                .onChange(of: model.entries.count) {
                    // Sending a message always jumps to the bottom; model output only follows while pinned.
                    if case .text(let last) = model.entries.last, last.role == .user { isPinnedToBottom = true }
                    if isPinnedToBottom { scrollToBottom(proxy) }
                }
            }
        }
    }

    /// Deferred one runloop turn so the scroll happens after the new content has been laid out.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    private let scrollSpace = "transcript"
    private let bottomID = "bottom"
}

private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct UsageBar: View {
    let usage: ChatUsage

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ContextMeter(fraction: usage.contextFraction)
                Text("\(Self.percent(usage.contextFraction)) context")
            }
            .help(
                "\(usage.contextTokens.formatted()) of \(ChatUsage.contextWindow.formatted()) tokens in the last request"
            )
            Text("\(Self.compact(usage.totals.input + usage.totals.cacheRead + usage.totals.cacheWrite)) in")
            Text("\(Self.compact(usage.totals.output)) out")
            if usage.requests > 0 {
                Text("\(Self.percent(usage.cacheHitRate)) cached")
                    .help(
                        "Cache reads \(usage.totals.cacheRead.formatted()), writes \(usage.totals.cacheWrite.formatted())"
                    )
            }
            Spacer(minLength: 0)
            Text(
                usage.estimatedCost,
                format: .currency(code: "USD").precision(.fractionLength(usage.estimatedCost < 1 ? 3 : 2))
            )
            .help("Estimated at Opus 5.5 list prices over \(usage.requests) requests")
        }
        .scaledFont(10)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private static func percent(_ fraction: Double) -> String {
        fraction > 0 && fraction < 0.001
            ? "<0.1%" : fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }

    private static func compact(_ tokens: Int) -> String {
        tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

private struct ContextMeter: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12))
            Capsule()
                .fill(fraction > 0.8 ? Color.orange : Color.accentColor)
                .frame(width: max(2, 28 * min(fraction, 1)))
        }
        .frame(width: 28, height: 4)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about what's on your screen.")
            Text("Tap Ctrl+Shift anywhere to attach the window you're on. /clear resets the chat.")
                .scaledFont(11)
                .foregroundStyle(.secondary)
        }
        .scaledFont(13)
        .padding(.top, 4)
    }
}

/// Port of Beautiful UI's loading state (beautifului.dev): a 3x3 pixel grid, shimmering label, and elapsed time.
private struct ThinkingRow: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            HStack(spacing: 10) {
                PixelGrid(time: now.timeIntervalSinceReferenceDate)
                ShimmerText(text: "Thinking", time: now.timeIntervalSinceReferenceDate)
                Text(String(format: "%.1fs", now.timeIntervalSince(startedAt)))
                    .scaledFont(12, design: .monospaced)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}

struct PixelGrid: View {
    private static let period = 0.65
    /// Per-pixel delays in seconds, row by row, matching the reference's diagonal sweep.
    private static let delays = [0.09, 0.18, 0.27, 0, 0.09, 0.18, 0.09, 0.18, 0.27]
    private static let restingOpacity = 0.15

    let time: TimeInterval

    var body: some View {
        Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary)
                            .frame(width: 4, height: 4)
                            .opacity(opacity(delay: Self.delays[row * 3 + column]))
                    }
                }
            }
        }
    }

    private func opacity(delay: Double) -> Double {
        let phase = ((time - delay) / Self.period).truncatingRemainder(dividingBy: 1)
        let pulse = (1 - cos(phase * 2 * .pi)) / 2
        return Self.restingOpacity + (1 - Self.restingOpacity) * pulse
    }
}

struct ShimmerText: View {
    private static let period = 1.4

    let text: String
    let time: TimeInterval

    var body: some View {
        let phase = (time / Self.period).truncatingRemainder(dividingBy: 1)
        Text(text)
            .scaledFont(13, weight: .medium)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.4), location: 0.35),
                        .init(color: .white, location: 0.5),
                        .init(color: .white.opacity(0.4), location: 0.65),
                    ],
                    startPoint: UnitPoint(x: 1.5 - phase * 2, y: 0.5),
                    endPoint: UnitPoint(x: 2.5 - phase * 2, y: 0.5)
                )
            )
    }
}

private struct TextRow: View {
    @ObservedObject var entry: TextEntry

    var body: some View {
        switch entry.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !entry.attachments.isEmpty {
                    AttachmentThumbnails(attachments: entry.attachments, size: 72)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .scaledFont(13)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Self.userBubble, in: Theme.surfaceShape)
                }
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    let segments = MessageSegment.split(entry.text)
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let isLast = index == segments.count - 1
                        switch segment {
                        case .prose(let text):
                            (Text(Self.markdown(text))
                                + Text(entry.isStreaming && isLast ? " ▍" : "").foregroundColor(.secondary))
                                .scaledFont(13)
                                .lineSpacing(2)
                        case .code(let code):
                            CodeBlock(code: code)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceFill, in: Theme.surfaceShape)
                .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
                if !entry.isStreaming, !entry.text.isEmpty, !entry.text.hasPrefix("_") {
                    MessageActions(text: entry.text)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: entry.isStreaming)
        }
    }

    private static let userBubble = Color(red: 0.0, green: 0.36, blue: 0.82).opacity(0.92)

    private var rendered: AttributedString { Self.markdown(entry.text) }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct QueueView: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.isQueuePaused ? "Queued, paused" : "Queued")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isQueuePaused {
                    Button("Resume", action: model.resumeQueue)
                        .buttonStyle(.plain)
                        .scaledFont(11, weight: .medium)
                        .foregroundStyle(Color.accentColor)
                }
            }
            ForEach(model.queue) { message in
                QueuedRow(
                    text: message.text,
                    onSendNow: { model.sendQueuedNow(message.id) },
                    onRemove: { model.removeQueued(message.id) }
                )
            }
        }
        .padding(10)
        .background(Theme.surfaceFill, in: Theme.surfaceShape)
        .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

private struct QueuedRow: View {
    let text: String
    let onSendNow: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .scaledFont(12)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            IconButton(systemName: "arrow.up", help: "Send now (interrupts the current reply)", action: onSendNow)
            IconButton(systemName: "xmark", help: "Remove from queue", action: onRemove)
        }
    }
}

private struct InputBar: View {
    @ObservedObject var model: ChatModel
    @FocusState private var isFocused: Bool

    @State private var highlighted = 0

    private var commandMatches: [SlashCommand] { SlashCommand.matches(for: model.input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !commandMatches.isEmpty {
                CommandMenu(commands: commandMatches, highlighted: min(highlighted, commandMatches.count - 1)) {
                    command in
                    model.input = command.name
                    submit()
                }
                .transition(.fadeUp)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    AttachmentThumbnails(attachments: model.attachments, size: 48, onRemove: model.removeAttachment)
                }
                field
            }
            .padding(10)
            .background(Theme.surfaceFill, in: Theme.surfaceShape)
            .overlay(
                Theme.surfaceShape.strokeBorder(
                    isDropTargeted ? Color.accentColor : AutoMode.isOn ? Color.orange.opacity(0.5) : Theme.stroke))
            AutoModeHint(model: model)
        }
        .animation(.fadeUp, value: commandMatches)
        .onChange(of: model.input) { highlighted = 0 }
        .padding(12)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted, perform: attachDropped)
        .onChange(of: model.focusRequest) { isFocused = true }
        .onAppear { isFocused = true }
    }

    @State private var isDropTargeted = false

    private var field: some View {
        HStack(spacing: 8) {
            TextField(
                model.isRunning ? "Queue a message, or Cmd+Return to send now" : "Ask about your screen...",
                text: $model.input, axis: .vertical
            )
            .textFieldStyle(.plain)
            .scaledFont(13)
            .lineLimit(1...6)
            .focused($isFocused)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.sendNow()
                return .handled
            }
            .onKeyPress(.downArrow) { moveHighlight(1) }
            .onKeyPress(.upArrow) { moveHighlight(-1) }
            // Shift+Tab can arrive as backtab (U+0019) rather than Tab with Shift.
            .onKeyPress(KeyEquivalent("\u{19}"), phases: .down) { _ in
                model.toggleAutoMode()
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    model.toggleAutoMode()
                    return .handled
                }
                guard let command = highlightedCommand else { return .ignored }
                model.input = command.name
                return .handled
            }
            .onSubmit(submit)
            // Backup for Cmd+Return in case the field consumes the key press first; a second call finds empty input.
            ShortcutKey(.return, action: model.sendNow)
            ShortcutKey("v", action: pasteImageOrText)
            IconButton(systemName: "camera", help: "Appshot: attach the current window (Ctrl+Shift)") {
                Task { await model.attachWindowScreenshot() }
            }
            IconButton(systemName: "photo", help: "Attach an image (or paste / drop one)", action: pickImages)
            SendControls(model: model)
        }
    }

    private var highlightedCommand: SlashCommand? {
        let matches = commandMatches
        return matches.isEmpty ? nil : matches[min(highlighted, matches.count - 1)]
    }

    private func moveHighlight(_ step: Int) -> KeyPress.Result {
        let count = commandMatches.count
        guard count > 0 else { return .ignored }
        highlighted = (min(highlighted, count - 1) + step + count) % count
        return .handled
    }

    /// Return with the command menu open runs the highlighted command, like Claude Code.
    private func submit() {
        if let command = highlightedCommand, SlashCommand.exact(model.input) == nil {
            model.input = command.name
        }
        model.send()
    }

    /// Cmd+V attaches a copied image; anything with text pastes into the field as usual.
    private func pasteImageOrText() {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard) {
            model.attach(image)
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let image = NSImage(contentsOf: url) { model.attach(image) }
        }
    }

    private func attachDropped(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                Task { @MainActor in model.attach(image) }
            }
        }
        return true
    }
}

/// Idle: send. Running: queue the draft behind the current reply (Return), send it now and interrupt
/// (Cmd+Return), or stop.
/// A reply split on ``` fences, so code and ASCII art render monospaced instead of wrapping in prose.
enum MessageSegment: Equatable {
    case prose(String)
    case code(String)

    static func split(_ text: String) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            if index.isMultiple(of: 2) {
                let prose = part.trimmingCharacters(in: .newlines)
                if !prose.isEmpty { segments.append(.prose(prose)) }
            } else {
                // Drop the language tag on the opening fence line ("```swift").
                var lines = part.components(separatedBy: "\n")
                if let first = lines.first, !first.contains(" ") { lines.removeFirst() }
                segments.append(.code(lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            }
        }
        return segments
    }
}

private struct CodeBlock: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .scaledFont(11.5, design: .monospaced)
                .fixedSize(horizontal: true, vertical: false)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.3), in: Theme.innerShape)
    }
}

private struct CommandMenu: View {
    let commands: [SlashCommand]
    let highlighted: Int
    let onChoose: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                Button {
                    onChoose(command)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.name)
                            .scaledFont(12, weight: .semibold, design: .monospaced)
                            .frame(width: 80, alignment: .leading)
                        Text(command.summary)
                            .scaledFont(12)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(index == highlighted ? 0.1 : 0), in: Theme.innerShape)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.surfaceFill, in: Theme.surfaceShape)
        .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
    }
}

/// Claude Code-style mode line under the input.
private struct AutoModeHint: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        let isOn = AutoMode.isOn
        Button(action: model.toggleAutoMode) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "forward.fill" : "hand.raised")
                    .scaledFont(9)
                Text(isOn ? "auto mode on" : "asks before computer use")
                Text("(shift+tab to cycle)").foregroundStyle(.tertiary)
            }
            .scaledFont(11)
            .foregroundStyle(isOn ? Color.orange : .secondary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(model.autoModeChanged)
        .help(
            isOn
                ? "Computer use runs without asking. Click or /auto to turn off."
                : "Click or /auto to always allow computer use.")
    }
}

private struct SendControls: View {
    @ObservedObject var model: ChatModel

    private var hasDraft: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            if model.isRunning {
                if hasDraft {
                    pill(
                        "Queue", systemName: "text.append", help: "Send after the current reply (Return)",
                        action: model.send)
                    pill(
                        "Send now", systemName: "bolt.fill", help: "Interrupt and send this now (Cmd+Return)",
                        action: model.sendNow)
                }
                round("stop.fill", help: "Stop", tint: .white.opacity(0.18), action: model.stop)
            } else {
                round(
                    "arrow.up", help: "Send (Return)", tint: hasDraft ? .accentColor : .white.opacity(0.12),
                    action: model.send
                )
                .disabled(!hasDraft)
            }
        }
        .animation(.fadeUp, value: model.isRunning)
        .animation(.fadeUp, value: hasDraft)
    }

    private func pill(_ label: String, systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemName)
                .scaledFont(11, weight: .medium)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func round(_ systemName: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(10, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AttachmentThumbnails: View {
    let attachments: [Attachment]
    let size: CGFloat
    var onRemove: ((UUID) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentChip(
                        attachment: attachment, size: size,
                        onRemove: onRemove.map { remove in { remove(attachment.id) } }
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.fadeUp, value: attachments.map(\.id))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Codex-style appshot chip: thumbnail with the app icon badge, plus app name and window title.
/// Plain images (pasted, dropped, picked) show as a bare thumbnail. Click to preview.
private struct AttachmentChip: View {
    let attachment: Attachment
    let size: CGFloat
    let onRemove: (() -> Void)?

    @State private var isHovering = false
    @State private var isPreviewing = false

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if let onRemove, isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.75))
                            .scaledFont(13)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Remove")
                    .transition(.opacity)
                }
            }
            .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
            .onTapGesture { isPreviewing = true }
            .popover(isPresented: $isPreviewing) {
                Image(nsImage: attachment.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 420)
                    .padding(8)
            }
            .help(attachment.source.map { "\($0.appName) \($0.windowTitle)" } ?? "Image")
    }

    @ViewBuilder
    private var content: some View {
        if let source = attachment.source {
            HStack(spacing: 8) {
                thumbnail(side: 34)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = source.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                                .offset(x: 4, y: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.appName)
                        .scaledFont(12, weight: .medium)
                        .lineLimit(1)
                    if !source.windowTitle.isEmpty {
                        Text(source.windowTitle)
                            .scaledFont(11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(Theme.surfaceFill, in: Theme.innerShape)
            .overlay(Theme.innerShape.strokeBorder(Theme.stroke))
        } else {
            thumbnail(side: size)
        }
    }

    private func thumbnail(side: CGFloat) -> some View {
        Image(nsImage: attachment.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke))
    }
}
