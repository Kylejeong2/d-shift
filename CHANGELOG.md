# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- Browser-style text zoom: Cmd+= and Cmd+- step the text size from 80% to 200%, Cmd+0 resets. The level is remembered.
- Message queue: send while Claude is replying and messages run in order. Queued messages can be sent immediately or removed; Stop pauses the queue.
- Cmd+Return sends immediately, interrupting the current reply. Interrupted replies stay in the conversation as context.
- Closing the last chat tab hides the sidebar; it reopens with a fresh chat.
- Clicking anywhere in the sidebar that isn't a button focuses the input.
- Resize the panel from the top edge and the top-left and bottom-left corners. Vertical position is remembered along with size, and resize cursors now appear even though the panel never activates the app.

### Changed

- The panel backdrop is more opaque (85%) so busy backgrounds show through less.
- Memory works in the background: `bash` and `save_memory` are replaced by hidden `search_memory` (read-only shell) and `write_memory` (`.md` files in the memory folder) tools. The model consults and updates memory without asking or announcing it.
- Screenshots are a last resort: the model only takes one when the accessibility snapshot lacks the information needed, at most one per question.
- Screen refreshes (`read_screen`) no longer show a card in the chat.

### Fixed

- Diagonal resizing from the left corners: the corner handles were clipped by the rounded corners and clicks passed through to the window behind.
- Commit memory sources that a case-insensitive ignore rule had excluded, which broke CI builds.

## [0.1.0] - 2026-10-01

### Added

- Double-Shift toggled, translucent, non-activating sidebar panel that floats over all apps and Spaces and is excluded from screen capture.
- Screen context from the focused window's accessibility tree, with live tracking of the active app and window title.
- Claude (Opus 5.5) chat with smooth frame-paced streaming and a tool-use agent loop with in-chat approval cards.
- Tools: `read_screen`, `take_screenshot`, `bash` (memory folder, read-only commands auto-approved), and `save_memory`.
- Markdown memory folder and JSONL chat history stored outside the repo (configurable with `DSHIFT_DATA_DIR`).
- Multiple chat tabs with separate model sessions.
- Per-chat usage bar: context window percentage, tokens, cache hit rate, and estimated cost.
- Resizable panel with persisted size, and pinned auto-scroll.

[Unreleased]: https://github.com/Kylejeong2/d-shift/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Kylejeong2/d-shift/releases/tag/v0.1.0
