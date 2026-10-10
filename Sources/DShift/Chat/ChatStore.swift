import Foundation

/// Owns the open chat tabs. Each tab is its own ChatModel, so it has a separate transcript and model session.
@MainActor
final class ChatStore: ObservableObject {
    let tracker = AppTracker()
    @Published private(set) var chats: [ChatModel]
    @Published private(set) var selectedID: UUID
    var onLastChatClosed: (() -> Void)?
    @Published var isHistoryOpen = false

    private func wire(_ chat: ChatModel) {
        chat.onStoreCommand = { [weak self] command in
            switch command {
            case .new: self?.newChat()
            case .history: self?.isHistoryOpen = true
            default: break
            }
        }
    }

    init() {
        let first = ChatModel(tracker: tracker)
        defer { wire(first) }
        chats = [first]
        selectedID = first.id
    }

    var selected: ChatModel {
        chats.first { $0.id == selectedID } ?? chats[0]
    }

    func newChat() {
        let chat = ChatModel(tracker: tracker)
        wire(chat)
        chats.append(chat)
        selectedID = chat.id
    }

    /// Reopens a saved chat in a tab, or switches to it if it's already open.
    func open(_ saved: SavedChat) {
        if chats.contains(where: { $0.id == saved.id }) { return select(saved.id) }
        let chat = ChatModel(tracker: tracker, restoring: saved)
        wire(chat)
        // Replace an untouched blank tab instead of piling up empty ones.
        if selected.entries.isEmpty, !selected.isRunning, let index = chats.firstIndex(where: { $0.id == selectedID }) {
            chats[index] = chat
        } else {
            chats.append(chat)
        }
        selectedID = chat.id
        selected.focusRequest += 1
    }

    func select(_ id: UUID) {
        selectedID = id
        selected.focusRequest += 1
    }

    func close(_ id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].stop()
        chats.remove(at: index)
        if chats.isEmpty {
            newChat()
            onLastChatClosed?()
            return
        }
        if id == selectedID { selectedID = chats[min(index, chats.count - 1)].id }
    }
}
