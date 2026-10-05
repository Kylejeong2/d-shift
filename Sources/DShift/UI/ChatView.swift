import SwiftUI

/// Shared surface tokens: one radius for bubbles, cards, and the input; a smaller one for tabs and nested media.
private enum Theme {
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
            Text("D-Shift sends your questions and screen context to Claude using your own key. The key is stored in your macOS Keychain.")
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
                }
            }
            IconButton(systemName: "plus", help: "New chat", action: store.newChat)
                .keyboardShortcut("t", modifiers: .command)
            ShortcutKey("w", action: { store.close(store.selectedID) })
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

private struct IconButton: View {
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
                        }
                        ForEach(model.entries) { entry in
                            switch entry {
                            case .text(let text): TextRow(entry: text)
                            case .tool(let call): ToolCallRow(entry: call)
                            }
                        }
                        if model.isRunning && !model.isStreamingText {
                            ThinkingRow()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: BottomOffsetKey.self, value: marker.frame(in: .named(scrollSpace)).maxY)
                            })
                    }
                    .padding(14)
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
            .help("\(usage.contextTokens.formatted()) of \(ChatUsage.contextWindow.formatted()) tokens in the last request")
            Text("\(Self.compact(usage.totals.input + usage.totals.cacheRead + usage.totals.cacheWrite)) in")
            Text("\(Self.compact(usage.totals.output)) out")
            if usage.requests > 0 {
                Text("\(Self.percent(usage.cacheHitRate)) cached")
                    .help("Cache reads \(usage.totals.cacheRead.formatted()), writes \(usage.totals.cacheWrite.formatted())")
            }
            Spacer(minLength: 0)
            Text(usage.estimatedCost, format: .currency(code: "USD").precision(.fractionLength(usage.estimatedCost < 1 ? 3 : 2)))
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
        fraction > 0 && fraction < 0.001 ? "<0.1%" : fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
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
            Text("It remembers what you tell it about yourself. /clear resets the chat.")
                .scaledFont(11)
                .foregroundStyle(.secondary)
        }
        .scaledFont(13)
        .padding(.top, 4)
    }
}

private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Thinking")
                .scaledFont(12)
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }
}

private struct TextRow: View {
    @ObservedObject var entry: TextEntry

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .scaledFont(13)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Self.userBubble, in: Theme.surfaceShape)
            }
        case .assistant:
            Text(rendered)
                .scaledFont(13)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceFill, in: Theme.surfaceShape)
                .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
        }
    }

    private static let userBubble = Color(red: 0.0, green: 0.36, blue: 0.82).opacity(0.92)

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: entry.text, options: options)) ?? AttributedString(entry.text)
    }
}

private struct ToolCallRow: View {
    @ObservedObject var entry: ToolCallEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    ToolStatusIcon(status: entry.status)
                    Text(entry.name)
                        .scaledFont(12, weight: .medium, design: .monospaced)
                    if !isExpanded, !entry.inputSummary.isEmpty {
                        Text(entry.inputSummary)
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .scaledFont(9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if entry.status == .running, let latest = entry.output.split(separator: "\n").last {
                Text(latest)
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
            }
            if let image = entry.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: isExpanded ? 400 : 120)
                    .clipShape(Theme.innerShape)
            }
            if isExpanded {
                ToolDetail(label: "Input", text: entry.inputSummary)
                ToolDetail(label: "Output", text: entry.output)
            }
            if entry.status == .awaitingApproval {
                ApprovalButtons(entry: entry)
            }
        }
        .padding(10)
        .background(Theme.surfaceFill, in: Theme.surfaceShape)
        .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }
}

private struct ToolStatusIcon: View {
    let status: ToolCallEntry.Status

    var body: some View {
        Group {
            switch status {
            case .preparing, .running:
                ProgressView().controlSize(.mini)
            case .awaitingApproval:
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .succeeded:
                Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark").foregroundStyle(.red)
            case .denied:
                Image(systemName: "nosign").foregroundStyle(.secondary)
            }
        }
        .scaledFont(10, weight: .bold)
        .frame(width: 14, height: 14)
    }
}

private struct ToolDetail: View {
    let label: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .scaledFont(10, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(text.prefix(2000))
                    .scaledFont(11, design: .monospaced)
                    .lineLimit(14)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ApprovalButtons: View {
    let entry: ToolCallEntry

    var body: some View {
        HStack {
            Spacer()
            Button("Deny") { entry.resolveApproval(false) }
            Button("Allow") { entry.resolveApproval(true) }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
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

    var body: some View {
        HStack(spacing: 8) {
            TextField(model.isRunning ? "Queue a message, or Cmd+Return to send now" : "Ask about your screen...", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .scaledFont(13)
                .lineLimit(1...6)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    model.sendNow()
                    return .handled
                }
                .onSubmit(model.send)
            // Backup for Cmd+Return in case the field consumes the key press first; a second call finds empty input.
            ShortcutKey(.return, action: model.sendNow)
            if model.isRunning {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Stop")
            }
        }
        .padding(10)
        .background(Theme.surfaceFill, in: Theme.surfaceShape)
        .overlay(Theme.surfaceShape.strokeBorder(Theme.stroke))
        .padding(12)
        .onChange(of: model.focusRequest) { isFocused = true }
        .onAppear { isFocused = true }
    }
}
