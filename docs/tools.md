# Tools

Tools are local functions Claude can call during a chat. Each call shows up in the transcript as a card with its status, input, and output.

## Built-in tools

| Tool | What it does | Approval |
|---|---|---|
| `read_screen` | Re-reads the focused window's accessibility tree | Never |
| `take_screenshot` | Captures the focused window (`scope: "window"`, default) or the whole display (`scope: "screen"`), downscaled to at most 1568 px on the long edge, JPEG | Never (macOS Screen Recording permission required) |
| `bash` | Runs a shell command in the memory folder | Only for commands outside the read-only policy ([memory.md](memory.md)) |
| `save_memory` | Appends a fact to `memory/notes.md` | Always |

## Adding a tool

Create a file in `Sources/DShift/Tools/`:

```swift
struct WordCountTool: Tool {
    let name = "word_count"
    let description = "Count the words in a piece of text."
    let inputSchema: JSON = [
        "type": "object",
        "properties": ["text": ["type": "string"]],
        "required": ["text"],
        "additionalProperties": false,
    ]

    func requiresApproval(for input: JSON) -> Bool { false }

    func run(_ input: JSON) async throws -> ToolOutput {
        let text = input["text"] as? String ?? ""
        return ToolOutput(text: "\(text.split(whereSeparator: \.isWhitespace).count)")
    }
}
```

Then register it in `ChatModel.init`:

```swift
tools = ToolRegistry(tools: [ReadScreenTool(tracker: tracker), /* ... */, WordCountTool()])
```

## Rules of thumb

- **Approval:** return `true` from `requiresApproval(for:)` for any input that writes, deletes, sends, or spends. It is called per call with the actual input, so a tool can allow safe inputs and gate risky ones (as `bash` does).
- **Validation:** tool input streams eagerly (`eager_input_streaming`), so the server doesn't validate it. `ToolRegistry.validate` checks required fields and non-empty strings. Validate anything stricter in `run`.
- **Errors:** throw from `run`. The error message is returned to Claude as an `is_error` result and shown on the card.
- **Images:** set `ToolOutput.jpeg` to return an image block alongside the text.
- **Blocking work:** `Tool` is `@MainActor`. Move slow or blocking work off the main actor with `Task.detached`, as `read_screen` and `bash` do.
- **Writing descriptions:** describe when to use the tool, not only what it does. That is what the model uses to decide.
