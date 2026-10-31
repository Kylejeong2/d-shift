import Foundation

/// Decides which shell commands memory search may run. The gate matters because the model also reads screen
/// content, which may contain injected instructions. Allowed: a pipeline of allowlisted read-only programs with
/// relative paths and no redirection, substitution, chaining, or command-executing flags.
enum ShellPolicy {
    private static let readOnlyPrograms: Set<String> = [
        "rg", "grep", "egrep", "fgrep", "find", "ls", "cat", "head", "tail", "wc", "tree", "file", "stat",
    ]
    private static let forbiddenCharacters: [Character] = [
        ";", "&", "`", "$", "<", ">", "\n", "\\", "(", ")", "{", "}",
    ]
    private static let forbiddenArguments: Set<String> = [
        "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls",
    ]

    static func isReadOnlyWithinFolder(_ command: String) -> Bool {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty,
            !command.contains(where: forbiddenCharacters.contains)
        else { return false }
        for segment in command.split(separator: "|", omittingEmptySubsequences: false) {
            let words = segment.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            guard let program = words.first, readOnlyPrograms.contains(program) else { return false }
            for word in words.dropFirst() {
                let escapesFolder =
                    word.hasPrefix("/") || word.contains("~") || word.contains("..") || word.contains("=/")
                    || (word.hasPrefix("-") && word.contains("/"))
                if escapesFolder || forbiddenArguments.contains(word) || word.hasPrefix("--pre") { return false }
            }
        }
        return true
    }
}

enum ShellRunner {
    private static let timeout: TimeInterval = 20
    private static let maxOutputChars = 30_000

    /// Runs `command` with bash in `directory`, merging stdout and stderr, and appends the exit status.
    static func run(_ command: String, in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return "Failed to start bash: \(error.localizedDescription)"
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        var output = String(decoding: data, as: UTF8.self)
        if output.count > maxOutputChars { output = String(output.prefix(maxOutputChars)) + "\n(output truncated)" }
        let status =
            process.terminationReason == .uncaughtSignal
            ? "killed after \(Int(timeout))s timeout" : "exit \(process.terminationStatus)"
        return (output.isEmpty ? "(no output)" : output) + "\n[\(status)]"
    }
}
