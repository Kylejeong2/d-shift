# Architecture

D-Shift is a single SwiftPM executable built on AppKit with SwiftUI views inside. It has no third-party dependencies.

## Components

| Area | Files | Responsibility |
|---|---|---|
| App | `App/AppDelegate.swift`, `App/SidebarController.swift`, `App/DoubleShiftMonitor.swift`, `App/ResizeHandle.swift`, `App/Config.swift` | Lifecycle, menu bar item, the panel window, the double-Shift trigger, edge resizing, settings |
| Context | `Context/AXSnapshot.swift`, `Context/AppTracker.swift` | Serializing the focused window's accessibility tree, following the frontmost app and window title live |
| Chat | `Chat/ChatModel.swift`, `Chat/ChatStore.swift`, `Chat/ClaudeClient.swift`, `Chat/Transcript.swift`, `Chat/Usage.swift` | One agent loop per tab, tab management, the streaming HTTP client, transcript entries, token accounting |
| Tools | `Tools/*.swift` | The `Tool` protocol, registry and validation, built-in tools, the shell policy |
| Memory | `Memory/Memory.swift` | Memory folder layout and seeding, the overview sent each turn, the JSONL chat log |
| UI | `UI/ChatView.swift` | Tabs, app header, transcript, tool cards, usage bar, input |

## The panel

`SidebarPanel` is a borderless `NSPanel` with `.nonactivatingPanel`. It can become key, so you can type into it, without activating D-Shift. The app you're asking about stays frontmost, so its accessibility tree and window title remain the "current" context. Other settings:

- `level = .floating` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, so it follows you across Spaces and over fullscreen apps.
- Visible in user screenshots and recordings; its own `take_screenshot` tool excludes the sidebar windows.
- A `NSVisualEffectView` backdrop at reduced opacity under a sibling `NSHostingView`. Only the backdrop is translucent, and the text stays fully opaque.
- Continuous-curve corners (`cornerCurve = .continuous`) to match macOS.

The window docks to the right edge. `ResizeHandle` views on the left, top, and bottom edges and the two left corners resize it with the opposite edges pinned, clamped to the screen. Size and distance from the top of the screen are saved to `UserDefaults`. Handles use always-active tracking areas for their cursors, because cursor rects only apply in the active app.

## Double-Shift detection

`DoubleShiftMonitor` listens to global and local `flagsChanged` and `keyDown` events. A tap is a Shift press and release under 250 ms with no other modifier. Two taps within 400 ms trigger it. Any other key resets the state, so typing capital letters never triggers it.

## Screen context

`AXSnapshot.capture(app:)` walks the focused window's accessibility tree (falling back to the main window), up to 3,000 nodes, depth 40, and 60k characters. Each node becomes one indented line: role, de-duplicated title, value, description, and placeholder text. The focused element is marked. Empty structural containers (`AXGroup` and similar) are skipped without adding indentation, to save tokens. Selected text is appended.

It sets `AXManualAccessibility` on the app element first, because Chrome and Electron only build a full tree once an assistive client asks for one.

`AppTracker` follows `NSWorkspace.didActivateApplicationNotification` for app switches, and an `AXObserver` for focused-window and title changes, so the header updates in real time.

## Agent loop

Each tab owns a `ChatModel`, which keeps its API transcript as raw JSON content blocks.

1. **User turn:** `<screen>` (only if it changed since the last send), `<memory>` (me.md plus the file list), then the question.
2. **Stream:** `ClaudeClient` turns SSE lines into `StreamEvent`s at content-block granularity. `AssistantMessage` accumulates blocks verbatim, including thinking blocks and their signatures, so they can be sent back unchanged as the API requires during tool use.
3. **Tools:** on `stop_reason == "tool_use"`, each `tool_use` block is validated, checked against its per-question call limit, approved if needed, and run. Hidden tools (memory, `read_screen`) run without a transcript row. The results go back in a single user message. Images (screenshots) are sent as image blocks inside `tool_result`.
4. The loop repeats on `tool_use` and `pause_turn`, up to 12 iterations. `refusal` and `max_tokens` end it with a note.
5. **Failure or Stop:** the transcript rolls back to before the turn, so it never contains a `tool_use` without its result.

Requests use `claude-opus-5-5` at `effort: low`, top-level prompt caching, and `fallbacks: "default"` (server-side refusal fallback).

## Streaming smoothness

`TextEntry` buffers incoming text and reveals it on a 60 Hz timer. Each frame reveals `max(1, backlog / 8)` characters, so output flows evenly and stays within roughly 130 ms of the network. Each entry is its own `ObservableObject`, so only the streaming row re-renders. A `ScrollSignal` tick keeps the transcript pinned to the bottom unless you've scrolled up.

## Usage accounting

`message_start` and `message_delta` usage fields are merged per request. `ChatUsage` totals input, output, cache-read, and cache-write tokens per tab. It records the last request's total as context-window usage (out of 1M) and estimates cost at Opus 5.5 list prices.
