# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

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
