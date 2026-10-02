import Foundation

/// Settings come from the process environment first, then dotenv files, then the keychain (where the app's
/// setup screen saves the API key).
/// Nothing user-specific is hardcoded so the app works the same for anyone who clones the repo.
enum Config {
    static func value(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        return dotenvFiles.lazy.compactMap { dotenvValue(name, in: $0) }.first ?? Keychain.read(name)
    }

    /// Where memory and chat history live. Defaults to Application Support so personal data sits outside the repo.
    static let dataDir: URL = {
        let dir: URL
        if let custom = value("DSHIFT_DATA_DIR") {
            dir = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DShift", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dotenvFiles: [URL] {
        [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dshift/.env"),
        ]
    }

    /// Reads `NAME=value` (optionally prefixed with `export`, optionally quoted) from a dotenv file.
    private static func dotenvValue(_ name: String, in file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard line.hasPrefix("\(name)=") else { continue }
            let value = line.dropFirst(name.count + 1)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
