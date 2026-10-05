# Tools

Tools are local functions Claude can call during a chat. Visible tools show up in the transcript as a card with their status, input, and output; hidden tools run in the background.

## Built-in tools

| Tool | What it does | Shown in chat | Limits |
|---|---|---|---|
| `read_screen` | Re-reads the focused window's accessibility tree | No | None |
| `take_screenshot` | Captures the focused window (`scope: "window"`, default) or the whole display (`scope: "screen"`), downscaled to at most 1568 px on the long edge, JPEG | Yes, with thumbnail | 1 per question, last resort; needs Screen Recording permission |
| `search_memory` | Read-only shell search in the memory folder | No | `ShellPolicy` ([memory.md](memory.md)) |
| `write_memory` | Creates, appends to, or replaces a `.md` file in the memory folder | No | Paths confined by `MemoryPath` |
| `use_computer` | Hands a task to Codex, which operates your apps in the background with its computer-use agent | Yes, with live progress | Always asks for approval; 3 per question; 10 minute timeout |

## Computer use through Codex

`use_computer` is available when the [Codex CLI](https://developers.openai.com/codex) is installed with Computer Use enabled and signed in. D-Shift looks for it at `DSHIFT_CODEX_PATH`, then the CLI bundled in ChatGPT.app, then common install locations. If none is found, the tool isn't offered.

Claude writes one complete, self-contained task, because Codex can't see the conversation. After you click Allow, D-Shift runs:

```
codex exec --json --ephemeral --skip-git-repo-check --sandbox read-only -C <data dir>/codex "<task>"
```

Codex's own model chooses the actions and drives your apps through its computer-use service, which works in the background without taking over the app you're using. The read-only sandbox stops Codex from running shell commands that change files. D-Shift parses the JSON event stream to show progress on the card, and returns Codex's final message to Claude. Stop terminates the process. Codex's stderr from the last run is kept at `<data dir>/codex/last-run-stderr.log` for debugging.

Usage counts against your Codex or ChatGPT plan, not your Anthropic key.

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

- **Approval:** return `true` from `requiresApproval(for:)` for any input that writes outside a sandbox, deletes, sends, or spends. It is called per call with the actual input, so a tool can allow safe inputs and gate risky ones.
- **Visibility:** set `isHidden = true` for background work the user doesn't need to see (as the memory tools and `read_screen` do). A hidden tool has no card, so it can't ask for approval: refuse unsafe input instead.
- **Rate limits:** set `maxCallsPerTurn` to cap calls per question (as `take_screenshot` does). Extra calls return an error telling the model to answer with what it has.
- **Validation:** tool input streams eagerly (`eager_input_streaming`), so the server doesn't validate it. `ToolRegistry.validate` checks required fields and non-empty strings. Validate anything stricter in `run`.
- **Errors:** throw from `run`. The error message is returned to Claude as an `is_error` result and shown on the card.
- **Images:** set `ToolOutput.jpeg` to return an image block alongside the text.
- **Blocking work:** `Tool` is `@MainActor`. Move slow or blocking work off the main actor with `Task.detached`, as `read_screen` and `search_memory` do.
- **Writing descriptions:** describe when to use the tool, not only what it does. That is what the model uses to decide.
