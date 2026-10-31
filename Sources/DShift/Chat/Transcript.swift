import AppKit

/// Bumped on every revealed frame so the transcript can stay pinned to the bottom.
@MainActor
final class ScrollSignal: ObservableObject {
    @Published var tick = 0
}

/// A screenshot or image the user attached to a message, already downscaled and JPEG-encoded for upload.
struct Attachment: Identifiable {
    private static let maxLongEdgePixels: CGFloat = 1568

    /// Where an appshot came from, shown on its chip and told to the model.
    struct Source {
        let appName: String
        let windowTitle: String
        let icon: NSImage?
    }

    let id: UUID
    let image: NSImage
    let jpeg: Data
    var source: Source?

    init?(image source: NSImage) {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, Self.maxLongEdgePixels / CGFloat(max(cgImage.width, cgImage.height)))
        let size = NSSize(width: CGFloat(cgImage.width) * scale, height: CGFloat(cgImage.height) * scale)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cgImage, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
            let image = NSImage(data: jpeg)
        else { return nil }
        self.id = UUID()
        self.image = image
        self.jpeg = jpeg
    }

    init?(jpeg: Data, id: UUID = UUID()) {
        guard let image = NSImage(data: jpeg) else { return nil }
        self.id = id
        self.image = image
        self.jpeg = jpeg
    }
}

struct QueuedMessage: Identifiable {
    let id = UUID()
    let text: String
    var attachments: [Attachment] = []
}

enum TranscriptEntry: Identifiable {
    case text(TextEntry)
    case tool(ToolCallEntry)

    var id: UUID {
        switch self {
        case .text(let entry): entry.id
        case .tool(let entry): entry.id
        }
    }
}

/// A message whose streamed text is revealed on a per-frame clock instead of in network-sized bursts.
/// Each frame drains a fraction of the backlog, so output stays smooth and never lags far behind the network.
@MainActor
final class TextEntry: ObservableObject, Identifiable {
    enum Role { case user, assistant }

    private static let frameInterval: TimeInterval = 1.0 / 60
    private static let framesToDrainBacklog = 8

    let id = UUID()
    let role: Role
    let attachments: [Attachment]
    @Published private(set) var text: String
    /// True while streamed text is still being revealed, so the view can show a caret.
    @Published private(set) var isStreaming = false

    private var pending = ""
    private var timer: Timer?
    private weak var scroll: ScrollSignal?

    init(role: Role, text: String = "", attachments: [Attachment] = [], scroll: ScrollSignal? = nil) {
        self.role = role
        self.attachments = attachments
        self.text = text
        self.scroll = scroll
    }

    func enqueue(_ chunk: String) {
        pending += chunk
        isStreaming = true
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.revealFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func flush() {
        text += pending
        pending = ""
        isStreaming = false
        stopTimer()
    }

    private func revealFrame() {
        guard !pending.isEmpty else { return stopTimer() }
        let step = max(1, pending.count / Self.framesToDrainBacklog)
        let cut = pending.index(pending.startIndex, offsetBy: step, limitedBy: pending.endIndex) ?? pending.endIndex
        text += pending[..<cut]
        pending.removeSubrange(..<cut)
        scroll?.tick += 1
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class ToolCallEntry: ObservableObject, Identifiable {
    enum Status { case preparing, awaitingApproval, running, succeeded, failed, denied, cancelled }

    let id = UUID()
    let toolUseID: String
    let name: String
    @Published var input: JSON = [:]
    @Published var status: Status = .preparing {
        didSet {
            if status == .running { startedAt = Date() }
            if [.succeeded, .failed, .denied, .cancelled].contains(status) { finishedAt = Date() }
        }
    }
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published var output = ""
    @Published var image: NSImage?

    private var approval: CheckedContinuation<Bool, Never>?

    init(toolUseID: String, name: String) {
        self.toolUseID = toolUseID
        self.name = name
    }

    var inputSummary: String {
        guard !input.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func requestApproval() async -> Bool {
        status = .awaitingApproval
        return await withCheckedContinuation { approval = $0 }
    }

    var isFinished: Bool { finishedAt != nil }

    /// Set while the tool runs; stops just this call.
    var onCancel: (() -> Void)?
    private(set) var isCancelRequested = false

    func cancel() {
        isCancelRequested = true
        onCancel?()
    }

    func resolveApproval(_ approved: Bool) {
        approval?.resume(returning: approved)
        approval = nil
    }

    /// App the running tool is asking permission to control, e.g. Codex Computer Use asking for "Slack".
    @Published private(set) var accessRequest: String?
    private var access: CheckedContinuation<AppAccess, Never>?

    func requestAccess(app: String) async -> AppAccess {
        accessRequest = app
        return await withCheckedContinuation { access = $0 }
    }

    func resolveAccess(_ decision: AppAccess) {
        accessRequest = nil
        access?.resume(returning: decision)
        access = nil
    }
}

enum AppAccess { case once, always, deny }
