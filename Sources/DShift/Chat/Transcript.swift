import AppKit

/// Bumped on every revealed frame so the transcript can stay pinned to the bottom.
@MainActor
final class ScrollSignal: ObservableObject {
    @Published var tick = 0
}

struct QueuedMessage: Identifiable {
    let id = UUID()
    let text: String
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
    @Published private(set) var text: String

    private var pending = ""
    private var timer: Timer?
    private weak var scroll: ScrollSignal?

    init(role: Role, text: String = "", scroll: ScrollSignal? = nil) {
        self.role = role
        self.text = text
        self.scroll = scroll
    }

    func enqueue(_ chunk: String) {
        pending += chunk
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
    enum Status { case preparing, awaitingApproval, running, succeeded, failed, denied }

    let id = UUID()
    let toolUseID: String
    let name: String
    @Published var input: JSON = [:]
    @Published var status: Status = .preparing
    @Published var output = ""
    @Published var image: NSImage?

    private var approval: CheckedContinuation<Bool, Never>?

    init(toolUseID: String, name: String) {
        self.toolUseID = toolUseID
        self.name = name
    }

    var inputSummary: String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func requestApproval() async -> Bool {
        status = .awaitingApproval
        return await withCheckedContinuation { approval = $0 }
    }

    func resolveApproval(_ approved: Bool) {
        approval?.resume(returning: approved)
        approval = nil
    }
}
