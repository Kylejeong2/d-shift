import Foundation

/// Read-only shell search over the memory folder. Hidden from the transcript; commands outside
/// `ShellPolicy` are refused rather than escalated, since there is no visible approval step.
struct MemorySearchTool: Tool {
    let isHidden = true
    let name = "search_memory"
    let description = """
    Search and read the user's memory folder (markdown files) with a read-only shell command run inside it: \
    `rg -n -i "term" .`, `grep -rni "term" .`, `find . -name "*.md"`, `cat people/alex.md`. Allowed programs: rg, \
    grep, find, ls, cat, head, tail, wc, tree, file, stat, piped together. Paths must be relative. No redirection, \
    chaining, or substitution.
    """
    let inputSchema: JSON = [
        "type": "object",
        "properties": ["command": ["type": "string", "description": "A read-only command to run in the memory folder."]],
        "required": ["command"],
        "additionalProperties": false,
    ]

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let command = input["command"] as? String ?? ""
        guard ShellPolicy.isReadOnlyWithinFolder(command) else {
            throw ToolError.invalidInput("only read-only search commands inside the memory folder are allowed")
        }
        let directory = Storage.memoryDir
        return await Task.detached { ToolOutput(text: ShellRunner.run(command, in: directory)) }.value
    }
}

/// Creates, appends to, or replaces a markdown file in the memory folder. Hidden and unprompted by design,
/// so it is confined to `.md` files inside the folder.
struct MemoryWriteTool: Tool {
    let isHidden = true
    let name = "write_memory"
    let description = """
    Save to the user's memory folder. `path` is relative, must end in .md, and folders are created as needed \
    (for example people/alex-chen.md). mode "append" adds content to the end (default); "replace" overwrites the \
    whole file, so read it first with search_memory and include everything worth keeping.
    """
    let inputSchema: JSON = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Relative path ending in .md."],
            "content": ["type": "string", "description": "Markdown to write."],
            "mode": ["type": "string", "enum": ["append", "replace"]],
        ],
        "required": ["path", "content"],
        "additionalProperties": false,
    ]

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let path = input["path"] as? String ?? ""
        guard let resolved = MemoryPath.resolve(path, inRoot: Storage.memoryDir.path) else {
            throw ToolError.invalidInput("path must be a relative .md path inside the memory folder")
        }
        let url = URL(fileURLWithPath: resolved)
        let content = input["content"] as? String ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if input["mode"] as? String == "replace" || !FileManager.default.fileExists(atPath: url.path) {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(("\n" + content).utf8))
        }
        return ToolOutput(text: "Saved \(path).")
    }
}
