import Foundation

/// Owns the open chat tabs. Each tab is its own ChatModel, so it has a separate transcript and model session.
@MainActor
final class ChatStore: ObservableObject {
    let tracker = AppTracker()
    @Published private(set) var chats: [ChatModel]
    @Published private(set) var selectedID: UUID

    init() {
        let first = ChatModel(tracker: tracker)
        chats = [first]
        selectedID = first.id
    }

    var selected: ChatModel {
        chats.first { $0.id == selectedID } ?? chats[0]
    }

    func newChat() {
        let chat = ChatModel(tracker: tracker)
        chats.append(chat)
        selectedID = chat.id
    }

    func select(_ id: UUID) {
        selectedID = id
        selected.focusRequest += 1
    }

    func close(_ id: UUID) {
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[index].stop()
        chats.remove(at: index)
        if chats.isEmpty { return newChat() }
        if id == selectedID { selectedID = chats[min(index, chats.count - 1)].id }
    }
}
