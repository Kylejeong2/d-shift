import SwiftUI

// Ports of Beautiful UI (beautifului.dev) primitives: tool chips, approval card, task rows, and message actions.

// MARK: - Motion

/// Beautiful UI's signature ease, cubic-bezier(0.23, 1, 0.32, 1).
extension Animation {
    static let fadeUp = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.38)
    static let glide = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
}

extension AnyTransition {
    static let fadeUp = AnyTransition.opacity.combined(with: .offset(y: 8))
}

/// The pixel-grid loader on its own clock, for places that don't already run a TimelineView.
private struct LivePixelGrid: View {
    var body: some View {
        TimelineView(.animation) { PixelGrid(time: $0.date.timeIntervalSinceReferenceDate) }
    }
}

private struct LiveShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { ShimmerText(text: text, time: $0.date.timeIntervalSinceReferenceDate) }
    }
}

// MARK: - Transcript grouping

/// Consecutive background tool calls collapse into one chip group; Codex runs get their own task row.
enum TranscriptItem: Identifiable {
    case text(TextEntry)
    case tools([ToolCallEntry])
    case task(ToolCallEntry)

    var id: UUID {
        switch self {
        case .text(let entry): entry.id
        case .tools(let calls): calls[0].id
        case .task(let call): call.id
        }
    }

    @MainActor
    static func group(_ entries: [TranscriptEntry]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for entry in entries {
            switch entry {
            case .text(let text):
                items.append(.text(text))
            case .tool(let call) where call.name == "use_computer":
                items.append(.task(call))
            case .tool(let call):
                if case .tools(let calls) = items.last {
                    items[items.count - 1] = .tools(calls + [call])
                } else {
                    items.append(.tools([call]))
                }
            }
        }
        return items
    }
}

// MARK: - Tool chips

struct ToolGroup: View {
    let calls: [ToolCallEntry]
    @State private var isExpanded = false

    var body: some View {
        if calls.count == 1 {
            ToolChip(entry: calls[0])
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .scaledFont(11)
                        Text("\(calls.count) tool calls")
                            .scaledFont(12)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .scaledFont(9, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverFillStyle())

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(calls) { ToolChip(entry: $0) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.stroke).frame(width: 1).padding(.leading, 5)
                    }
                    .transition(.fadeUp)
                } else if let active = calls.last(where: { !$0.isFinished }) {
                    // Collapsed groups still surface the call in flight, including approvals.
                    ToolChip(entry: active)
                        .id(active.id)
                        .transition(.opacity)
                }
            }
            .animation(.fadeUp, value: isExpanded)
        }
    }
}

private struct ToolChip: View {
    @ObservedObject var entry: ToolCallEntry
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.status == .awaitingApproval {
                ApprovalCard(
                    title: "Allow \(label.lowercased())?", detail: entry.inputSummary, onResolve: entry.resolveApproval)
            } else {
                chip
            }
            if let image = entry.image, entry.name == "make_diagram" {
                DiagramImage(image: image)
            } else if let image = entry.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: isExpanded ? 400 : 120)
                    .clipShape(Theme.innerShape)
                    .overlay(Theme.innerShape.strokeBorder(Theme.stroke))
            }
            if isExpanded {
                Group {
                    ToolDetail(label: "Input", text: entry.inputSummary)
                    ToolDetail(label: "Output", text: entry.output)
                }
                .transition(.fadeUp)
            }
        }
        .animation(.fadeUp, value: isExpanded)
        .animation(.fadeUp, value: entry.status)
    }

    private var chip: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                ToolStatusIcon(status: entry.status)
                if entry.isFinished {
                    Text(label).scaledFont(12, weight: .medium)
                } else {
                    LiveShimmerText(text: label)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 9)
            .frame(height: 24)
            .background(Theme.surfaceFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide details" : "Show details")
    }

    private var label: String {
        switch entry.name {
        case "read_screen": "Read screen"
        case "take_screenshot": "Screenshot"
        case "search_memory": "Searched memory"
        case "write_memory": "Saved to memory"
        case "make_diagram": entry.isFinished ? "Diagram" : "Drawing diagram"
        case "web_search": entry.isFinished ? "Searched the web" : "Searching the web"
        case "web_fetch": entry.isFinished ? "Read page" : "Reading page"
        default: entry.name
        }
    }

    private var summary: String {
        let input = entry.input
        return (input["title"] ?? input["query"] ?? input["url"] ?? input["command"] ?? input["path"] ?? input["scope"])
            as? String ?? ""
    }
}

private struct ToolStatusIcon: View {
    let status: ToolCallEntry.Status

    var body: some View {
        Group {
            switch status {
            case .preparing, .running, .awaitingApproval:
                LivePixelGrid().scaleEffect(0.75)
            case .succeeded:
                Image(systemName: "checkmark").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark").foregroundStyle(.red)
            case .denied, .cancelled:
                Image(systemName: "nosign").foregroundStyle(.secondary)
            }
        }
        .scaledFont(9, weight: .bold)
        .frame(width: 14, height: 14)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
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
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceFill, in: Theme.innerShape)
        }
    }
}

// MARK: - Approval card

struct ApprovalChoice: Identifiable {
    let label: String
    let systemName: String
    var tint: Color = .secondary
    let action: () -> Void

    var id: String { label }
}

/// A question with a highlight that glides between choices on hover.
private struct ApprovalCard: View {
    let title: String
    let detail: String
    let choices: [ApprovalChoice]
    let onDismiss: () -> Void

    @State private var hovered: String?
    @Namespace private var glide

    init(title: String, detail: String, choices: [ApprovalChoice], onDismiss: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.choices = choices
        self.onDismiss = onDismiss
    }

    /// Plain allow/deny.
    init(title: String, detail: String, onResolve: @escaping (Bool) -> Void) {
        self.init(
            title: title, detail: detail,
            choices: [
                ApprovalChoice(label: "Allow", systemName: "checkmark.circle", tint: .green) { onResolve(true) },
                ApprovalChoice(label: "Deny", systemName: "xmark.circle") { onResolve(false) },
            ], onDismiss: { onResolve(false) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(title)
                    .scaledFont(13, weight: .medium)
                Spacer(minLength: 8)
                IconButton(systemName: "xmark", help: "Deny", action: onDismiss)
            }
            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(12)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(choices) { row($0) }
            }
        }
        .padding(12)
        .background(Theme.surfaceFill, in: Theme.surfaceShape)
        .overlay(Theme.surfaceShape.strokeBorder(Color.orange.opacity(0.35)))
        .transition(.fadeUp)
    }

    private func row(_ choice: ApprovalChoice) -> some View {
        Button(action: choice.action) {
            HStack(spacing: 6) {
                Image(systemName: choice.systemName)
                    .foregroundStyle(choice.tint)
                Text(choice.label)
                    .foregroundStyle(hovered == choice.id ? .primary : .secondary)
                Spacer()
            }
            .scaledFont(13)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                if hovered == choice.id {
                    Theme.innerShape.fill(.white.opacity(0.08))
                        .matchedGeometryEffect(id: "highlight", in: glide)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            withAnimation(.glide) {
                if isInside { hovered = choice.id } else if hovered == choice.id { hovered = nil }
            }
        }
    }
}

// MARK: - Task rows

/// A Codex `use_computer` run: live status, elapsed time, and its progress steps on expand.
struct TaskRow: View {
    @ObservedObject var entry: ToolCallEntry
    @State private var isExpanded = false

    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        if entry.status == .awaitingApproval {
            ApprovalCard(title: "Let Codex do this?", detail: task, onResolve: entry.resolveApproval)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            header
                        }
                        .buttonStyle(.plain)
                        if entry.status == .running {
                            Button(action: entry.cancel) {
                                Image(systemName: "stop.fill")
                                    .scaledFont(9)
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.12), in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 10)
                            .help("Stop this computer task")
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    if isExpanded {
                        steps.transition(.fadeUp)
                    }
                }
                .background(Theme.surfaceFill, in: Self.shape)
                .overlay(Self.shape.strokeBorder(Theme.stroke))
                if let app = entry.accessRequest {
                    ApprovalCard(
                        title: "Allow Computer Use to use \(app)?",
                        detail: "Codex needs permission to control this app to finish the task.",
                        choices: [
                            ApprovalChoice(label: "Allow once", systemName: "checkmark.circle", tint: .green) {
                                entry.resolveAccess(.once)
                            },
                            ApprovalChoice(label: "Always allow \(app)", systemName: "checkmark.seal", tint: .green) {
                                entry.resolveAccess(.always)
                            },
                            ApprovalChoice(label: "Deny", systemName: "xmark.circle") { entry.resolveAccess(.deny) },
                        ],
                        onDismiss: { entry.resolveAccess(.deny) }
                    )
                }
            }
            .animation(.fadeUp, value: isExpanded)
            .animation(.fadeUp, value: entry.status)
            .animation(.fadeUp, value: entry.accessRequest)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusBadge
            Text(task)
                .scaledFont(13, weight: .medium)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let startedAt = entry.startedAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    Text(String(format: "%.1fs", (entry.finishedAt ?? timeline.date).timeIntervalSince(startedAt)))
                        .scaledFont(11, design: .monospaced)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            StatusPill(status: entry.status)
            Image(systemName: "chevron.down")
                .scaledFont(9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    private var statusBadge: some View {
        Group {
            switch entry.status {
            case .preparing, .running, .awaitingApproval: LivePixelGrid()
            case .succeeded: badge("checkmark", color: .green)
            case .failed: badge("xmark", color: .red)
            case .denied, .cancelled: badge("nosign", color: .gray)
            }
        }
        .frame(width: 20, height: 20)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private func badge(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .scaledFont(9, weight: .bold)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(color, in: Circle())
    }

    private var steps: some View {
        let lines = entry.output.split(separator: "\n").suffix(12)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(12)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if lines.isEmpty {
                Text(task).scaledFont(12).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 20)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.leading, 9)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var task: String { entry.input["task"] as? String ?? "Computer task" }
}

private struct StatusPill: View {
    let status: ToolCallEntry.Status

    var body: some View {
        let (label, color): (String, Color) =
            switch status {
            case .preparing, .running: ("Running", .blue)
            case .awaitingApproval: ("Waiting", .orange)
            case .succeeded: ("Completed", .green)
            case .failed: ("Failed", .red)
            case .denied: ("Denied", .gray)
            case .cancelled: ("Cancelled", .gray)
            }
        Text(label)
            .scaledFont(11, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(color.opacity(0.15), in: Capsule())
    }
}

// MARK: - Message actions

/// The action row under a finished reply.
struct MessageActions: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: copy) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .scaledFont(11)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverFillStyle())
            .foregroundStyle(didCopy ? Color.green : .secondary)
            .help("Copy")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }
}

private struct HoverFillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverFill(configuration: configuration)
    }

    private struct HoverFill: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    Theme.innerShape.fill(.white.opacity(configuration.isPressed ? 0.12 : isHovered ? 0.07 : 0))
                )
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovered)
        }
    }
}

/// Full-width diagram. Click to open it larger; the menu copies or saves it.
private struct DiagramImage: View {
    let image: NSImage
    @State private var isZoomed = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(Theme.innerShape)
            .overlay(Theme.innerShape.strokeBorder(Theme.stroke))
            .onTapGesture { isZoomed = true }
            .popover(isPresented: $isZoomed) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(image.size.width, 900))
                    .padding(8)
            }
            .contextMenu {
                Button("Copy Image") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button("Save to Downloads") {
                    let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("diagram-\(Int(Date().timeIntervalSince1970)).jpg")
                    if let tiff = image.tiffRepresentation,
                        let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
                    {
                        try? jpeg.write(to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            .help("Click to enlarge, right-click to copy or save")
    }
}
