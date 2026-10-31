import Foundation

enum Storage {
    static let memoryDir: URL = {
        let dir = Config.dataDir.appendingPathComponent("memory", isDirectory: true)
        Memory.seedIfNeeded(dir)
        return dir
    }()

    static let historyDir = Config.directory("history")
}

/// Memory is a plain folder of markdown files. The model searches and edits it with hidden tools;
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

enum MemoryPath {
    /// Resolves a model-supplied relative path to a markdown file inside `rootPath`, or nil if it would escape it.
    /// Symlinks are resolved so a link inside the folder can't point writes elsewhere.
    static func resolve(_ relativePath: String, inRoot rootPath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard url.pathExtension == "md",
              url.path.hasPrefix(root.path + "/"),
              url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(resolvedRoot)
        else { return nil }
        return url.path
    }
}
