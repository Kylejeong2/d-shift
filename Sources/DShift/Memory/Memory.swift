import Foundation

enum Storage {
    static let memoryDir: URL = {
        let dir = Config.dataDir.appendingPathComponent("memory", isDirectory: true)
        Memory.seedIfNeeded(dir)
        return dir
    }()

    static let historyDir: URL = {
        let dir = Config.dataDir.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

/// Memory is a plain folder of markdown files. The model reads and searches it with the bash tool;
/// only `me.md` and the file list are sent up front.
enum Memory {
    private static let maxListedFiles = 200

    static func overview() -> String {
        let profile = (try? String(contentsOf: Storage.memoryDir.appendingPathComponent("me.md"), encoding: .utf8)) ?? ""
        let files = markdownFiles()
        let listing = files.prefix(maxListedFiles).joined(separator: "\n")
            + (files.count > maxListedFiles ? "\n(\(files.count - maxListedFiles) more)" : "")
        return "## me.md\n\(profile)\n\n## Files\n\(listing)"
    }

    static func remember(_ note: String) throws {
        let notes = Storage.memoryDir.appendingPathComponent("notes.md")
        let line = "- \(ISO8601DateFormatter().string(from: Date())): \(note)\n"
        if let handle = try? FileHandle(forWritingTo: notes) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try ("# Notes\n\n" + line).write(to: notes, atomically: true, encoding: .utf8)
        }
    }

    fileprivate static func seedIfNeeded(_ dir: URL) {
        let fileManager = FileManager.default
        for folder in ["people", "projects"] {
            try? fileManager.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let seeds = [
            "me.md": "# About me\n\n- Name:\n- Role:\n- Writing style:\n",
            "notes.md": "# Notes\n\n",
        ]
        for (name, contents) in seeds where !fileManager.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try? contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private static func markdownFiles() -> [String] {
        let root = Storage.memoryDir.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: Storage.memoryDir, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" }
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: root, with: "") }
            .sorted()
    }
}

/// Append-only JSONL chat log, one file per day.
enum ChatHistory {
    private struct Entry: Encodable {
        let timestamp: Date
        let role: String
        let text: String
        let app: String?
        let chat: UUID
    }

    static func append(role: String, text: String, app: String?, chat: UUID) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let file = Storage.historyDir.appendingPathComponent("\(day).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(Entry(timestamp: Date(), role: role, text: text, app: app, chat: chat)) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: file)
        }
    }
}
