# D-Shift

A screen-aware AI sidebar for macOS. Double-tap **Shift** anywhere, ask a question, and Claude answers using what's on your screen and a local memory of who you are.

- **Sees your screen without screenshots by default.** It reads the macOS accessibility tree of the window you're looking at, which is exact and cheap. When that isn't enough (images, charts, design apps) the model can take a screenshot.
- **Remembers you, locally.** Memory is a plain folder of markdown files on your Mac. The model searches it with `grep`/`rg` through a sandboxed Bash tool, and asks before it writes anything.
- **Stays out of the way.** A translucent, non-activating panel that floats over every app and Space, never steals focus from the app you're asking about, and is hidden from screen recordings.
- **Multiple chats.** Tabs, each with its own conversation and model session, plus live token, context-window, cache, and cost stats per chat.

> Status: early (v0.x). macOS only. Expect rough edges and breaking changes.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ (Xcode or the Command Line Tools: `xcode-select --install`)
- An [Anthropic API key](https://console.anthropic.com)

## Quick start

```bash
git clone https://github.com/Kylejeong2/d-shift.git
cd d-shift
cp .env.example .env        # then set ANTHROPIC_API_KEY
swift run
```

On first launch macOS asks for **Accessibility** access. Grant it, then relaunch. A shift icon appears in the menu bar.

Double-tap **Shift** to open or close the sidebar.

### Permissions

| Permission | Why | When it's requested |
|---|---|---|
| Accessibility | Detect double-Shift, read the focused window's accessibility tree, follow the active app | First launch |
| Screen Recording | The `take_screenshot` tool | The first time the model takes a screenshot |

When you launch with `swift run`, macOS attributes these permissions to your **terminal app**, not to D-Shift. Grant them to the terminal and relaunch.

## Using it

| Action | How |
|---|---|
| Open / close | Double-tap Shift, or Esc to close |
| New chat tab | Cmd+T or the + button |
| Close chat tab | Cmd+W or the x on the tab |
| Resize | Drag the left edge (width) or bottom edge (height). The size is remembered. |
| Reset a chat | Type `/clear` |
| Open memory folder | Menu bar icon > Open Memory Folder |

The row above the input shows, for the current chat: how full the context window was on the last request, total input and output tokens, the prompt-cache hit rate, and an estimated cost at list prices.

## How it works

```
 Double-Shift ──> Sidebar panel (SwiftUI in a non-activating NSPanel)
                        │
                        v
   Accessibility tree of the focused window  +  me.md + memory file list
                        │
                        v
          Claude (Messages API, streaming, tool use loop)
                        │
          ┌─────────────┼───────────────┬──────────────┐
          v             v               v              v
     read_screen   take_screenshot     bash        save_memory
     (AX tree)     (ScreenCaptureKit)  (memory dir) (approval)
```

1. On send, D-Shift snapshots the accessibility tree of the frontmost app's focused window and serializes it into compact indented text. The snapshot is only re-sent when it changes.
2. Each request also carries `me.md` and the list of memory files, so the model knows what it can look up.
3. Claude streams back text and tool calls. Tools run locally; results go back to Claude until it finishes. Tools that change anything wait for your approval in the chat.
4. Streaming text is revealed on a 60 fps clock that drains a fraction of the backlog each frame, so output is smooth rather than bursty.

More detail in [docs/architecture.md](docs/architecture.md).

## Memory

Memory is a folder of markdown files. Nothing is hidden in a database, so you can open, edit, grep, or back it up yourself.

```
~/Library/Application Support/DShift/
├── memory/
│   ├── me.md          # your profile, sent with every request
│   ├── notes.md       # quick facts saved by save_memory
│   ├── people/        # one file per person
│   └── projects/      # one file per project
└── history/
    └── 2026-10-01.jsonl   # append-only chat log, one file per day
```

The model searches memory with the `bash` tool, which runs in the memory folder. Read-only searches inside that folder (`rg`, `grep`, `find`, `cat`, `ls`, and similar, piped together) run immediately. Anything else, such as writing a file, redirecting output, running other programs, or touching paths outside the folder, shows an Allow / Deny card first.

Your data never lives in the repo by default. To keep it somewhere else, set `DSHIFT_DATA_DIR` in `.env`. If you point it inside the repo, `data/`, `memory/`, and `history/` are already git-ignored.

See [docs/memory.md](docs/memory.md).

## Configuration

Settings are read from the environment first, then `./.env`, then `~/.config/dshift/.env`.

| Variable | Default | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | none (required) | API key |
| `DSHIFT_DATA_DIR` | `~/Library/Application Support/DShift` | Memory and chat history location |

Model settings live in `Sources/DShift/Chat/ClaudeClient.swift`: the model (`claude-opus-5-5`) and effort (`low`, for fast sidebar answers).

## Privacy

- Memory and history stay on your Mac.
- Screen context (the accessibility snapshot, and screenshots when the model takes one) and the memory overview are sent to the Anthropic API with your questions. Don't use D-Shift on screens you aren't comfortable sending.
- The sidebar excludes itself from screenshots and screen recordings.
- The Bash tool strips `ANTHROPIC_API_KEY` from the environment of commands it runs.

## Development

```bash
swift build            # debug build
swift run              # build and launch
./scripts/test.sh      # run tests (works with Xcode or Command Line Tools only)
```

Project layout:

```
Sources/DShift/
├── App/       app lifecycle, panel window, double-Shift monitor, resize, config
├── Chat/      chat model and agent loop, tabs, Claude streaming client, usage
├── Context/   accessibility snapshots, active-app tracking
├── Memory/    memory folder, chat history log
├── Tools/     tool protocol and registry, screen tools, bash, memory tools
└── UI/        SwiftUI views
Tests/DShiftTests/
docs/
```

Adding a tool: implement the `Tool` protocol in `Sources/DShift/Tools/`, return `true` from `requiresApproval(for:)` for any input that could change something, and register it in `ChatModel`. See [docs/tools.md](docs/tools.md).

## Roadmap

- Inline autocomplete in any text field using the same context and memory, with local inference via MLX ([docs/roadmap-autocomplete.md](docs/roadmap-autocomplete.md))
- Persist chat tabs across restarts
- OCR fallback for apps with thin accessibility trees
- Packaged, signed `.app` release

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). For security issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
