import Foundation

/// Appends timestamped lines to `logs/dshift.log` in the data dir and echoes them to stdout, so `scripts/dev.sh`
/// shows them live. Never log API keys or message contents beyond what's needed to debug.
enum Log {
    static let dir: URL = {
        let dir = Config.dataDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let file = dir.appendingPathComponent("dshift.log")
    private static let queue = DispatchQueue(label: "dshift.log")

    static func info(_ category: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) [\(category)] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        queue.async {
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}
