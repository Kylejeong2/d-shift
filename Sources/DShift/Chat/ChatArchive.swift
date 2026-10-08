import AppKit

/// A chat as saved to disk, enough to reopen it with its transcript and model context intact.
struct SavedChat: Codable, Identifiable {
    struct Entry: Codable {
        enum Kind: String, Codable { case user, assistant, tool }

        var kind: Kind
        var text: String
        var attachmentIDs: [UUID] = []
        var toolName: String?
        var toolInput: String?
        var toolFailed: Bool?
    }

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var app: String?
    var entries: [Entry]

    var preview: String {
        entries.first { $0.kind == .assistant }?.text ?? ""
    }
}

/// Saved chats live in `history/chats/<id>/`: `chat.json` for the transcript, `api.json` for the raw model messages,
/// and one JPEG per attached image. The daily JSONL log in `ChatHistory` stays as a plain-text audit trail.
enum ChatArchive {
    static let dir: URL = {
        let dir = Storage.historyDir.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(_ chat: SavedChat, apiMessages: [JSON], attachments: [Attachment]) {
        let folder = dir.appendingPathComponent(chat.id.uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for attachment in attachments {
            let file = folder.appendingPathComponent("\(attachment.id.uuidString).jpg")
            if !fileManager.fileExists(atPath: file.path) { try? attachment.jpeg.write(to: file) }
        }
        if let api = try? JSONSerialization.data(withJSONObject: apiMessages) {
            try? api.write(to: folder.appendingPathComponent("api.json"), options: .atomic)
        }
        try? encoder.encode(chat).write(to: folder.appendingPathComponent("chat.json"), options: .atomic)
    }

    /// Newest first. Skips folders that fail to decode rather than failing the whole list.
    static func list() -> [SavedChat] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("chat.json")) }
            .compactMap { try? decoder.decode(SavedChat.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func apiMessages(for id: UUID) -> [JSON] {
        let file = dir.appendingPathComponent(id.uuidString).appendingPathComponent("api.json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [JSON] ?? []
    }

    static func attachment(_ attachmentID: UUID, in chatID: UUID) -> Attachment? {
        let file = dir.appendingPathComponent(chatID.uuidString).appendingPathComponent("\(attachmentID.uuidString).jpg")
        return (try? Data(contentsOf: file)).flatMap { Attachment(jpeg: $0, id: attachmentID) }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id.uuidString))
    }
}
