import ScreenCaptureKit
import SwiftUI

// MARK: - History

struct HistoryButton: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        IconButton(systemName: "clock.arrow.circlepath", help: "Chat history (Cmd+Y)") { store.isHistoryOpen.toggle() }
            .keyboardShortcut("y", modifiers: .command)
            .popover(isPresented: $store.isHistoryOpen, arrowEdge: .bottom) {
                HistoryList(store: store) { store.isHistoryOpen = false }
            }
    }
}

private struct HistoryList: View {
    @ObservedObject var store: ChatStore
    let onOpen: () -> Void

    @State private var chats = ChatArchive.list()
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search chats", text: $query)
                .textFieldStyle(.plain)
                .scaledFont(13)
                .padding(8)
                .background(Theme.surfaceFill, in: Theme.innerShape)
            if filtered.isEmpty {
                Text(chats.isEmpty ? "No saved chats yet." : "No matches.")
                    .scaledFont(12)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { chat in
                            HistoryRow(chat: chat, isOpen: store.chats.contains { $0.id == chat.id }) {
                                store.open(chat)
                                onOpen()
                            } onDelete: {
                                ChatArchive.delete(chat.id)
                                withAnimation(.fadeUp) { chats.removeAll { $0.id == chat.id } }
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 320, height: 380, alignment: .top)
    }

    private var filtered: [SavedChat] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return chats }
        return chats.filter { chat in
            chat.title.localizedCaseInsensitiveContains(needle)
                || chat.entries.contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }
    }
}

private struct HistoryRow: View {
    let chat: SavedChat
    let isOpen: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chat.title)
                        .scaledFont(13, weight: .medium)
                        .lineLimit(1)
                    if isOpen {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    }
                }
                Text(chat.preview)
                    .scaledFont(11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text([chat.app, chat.updatedAt.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · "))
                    .scaledFont(10)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if isHovering {
                IconButton(systemName: "trash", help: "Delete chat", action: onDelete)
            }
        }
        .padding(8)
        .background(.white.opacity(isHovering ? 0.07 : 0), in: Theme.innerShape)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Feedback

/// Captures a screenshot of the display the sidebar is on (sidebar included) plus a note and the current chat,
/// so a coding agent can read `feedback/` and iterate on the app.
struct FeedbackButton: View {
    @ObservedObject var store: ChatStore
    @State private var isPresented = false
    @State private var screenshot: NSImage?

    var body: some View {
        IconButton(systemName: "exclamationmark.bubble", help: "Send feedback on the sidebar") {
            Task {
                // Capture before the popover opens so the shot shows what the feedback is about.
                screenshot = try? await Feedback.captureDisplay()
                isPresented = true
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            FeedbackComposer(screenshot: screenshot) { note, includeScreenshot in
                Feedback.save(note: note, screenshot: includeScreenshot ? screenshot : nil, chat: store.selected)
                isPresented = false
            }
        }
    }
}

private struct FeedbackComposer: View {
    let screenshot: NSImage?
    let onSend: (String, Bool) -> Void

    @State private var note = ""
    @State private var includeScreenshot = true
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should change?")
                .scaledFont(13, weight: .medium)
            TextField("Describe the bug or idea...", text: $note, axis: .vertical)
                .textFieldStyle(.plain)
                .scaledFont(13)
                .lineLimit(4...10)
                .focused($isFocused)
                .padding(8)
                .background(Theme.surfaceFill, in: Theme.innerShape)
            if let screenshot {
                Toggle(isOn: $includeScreenshot) {
                    Image(nsImage: screenshot)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 80)
                        .clipShape(Theme.innerShape)
                        .opacity(includeScreenshot ? 1 : 0.35)
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Text("Saved to \(Feedback.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    .scaledFont(10)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Save") { onSend(note, includeScreenshot) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}

@MainActor
enum Feedback {
    static let dir: URL = {
        let dir = Config.dataDir.appendingPathComponent("feedback", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let transcriptTail = 8

    static func captureDisplay() async throws -> NSImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }

        let configuration = SCStreamConfiguration()
        let scale = screen?.backingScaleFactor ?? 2
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: configuration
        )
        return NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))
    }

    static func save(note: String, screenshot: NSImage?, chat: ChatModel) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let folder = dir.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let screenshot,
           let tiff = screenshot.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: folder.appendingPathComponent("screen.png"))
        }

        let transcript = chat.entries.suffix(transcriptTail).map { entry -> String in
            switch entry {
            case .text(let text): "**\(text.role == .user ? "User" : "Assistant")**: \(text.text)"
            case .tool(let call): "**Tool** `\(call.name)` \(call.inputSummary) -> \(call.status)"
            }
        }.joined(separator: "\n\n")
        let markdown = """
        # Feedback \(stamp)

        \(note.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Context
        - Focused app: \(chat.tracker.app?.localizedName ?? "none")
        - Chat: \(chat.title)
        - Screenshot: \(screenshot == nil ? "none" : "screen.png")

        ## Recent transcript
        \(transcript.isEmpty ? "(empty)" : transcript)
        """
        try? markdown.write(to: folder.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)

        let line = "- [ ] \(stamp): \(note.split(separator: "\n").first ?? "") (\(stamp)/note.md)\n"
        let inbox = dir.appendingPathComponent("INBOX.md")
        if let handle = try? FileHandle(forWritingTo: inbox) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? ("# Feedback inbox\n\n" + line).write(to: inbox, atomically: true, encoding: .utf8)
        }
    }
}
