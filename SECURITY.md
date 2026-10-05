# Security Policy

D-Shift reads your screen, runs shell commands, and sends context to a third-party API, so security reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's [private vulnerability reporting](https://github.com/Kylejeong2/d-shift/security/advisories/new) instead, with steps to reproduce and the impact. You should get an acknowledgement within a few days.

## Scope

Especially interesting:

- Bypasses of `ShellPolicy`: a memory search command that writes files, executes other programs, or reads outside the memory folder.
- Bypasses of `MemoryPath`: a memory write that lands outside the memory folder or in a non-markdown file.
- Prompt-injection paths where on-screen content leads to an unapproved state change.
- Leakage of the API key, memory, or history outside the documented data flows.

## Known limitations

- Screen context and memory overviews are sent to the Anthropic API by design. See the Privacy section of the README.
- `use_computer` lets Codex operate any app. It always asks for approval and shows the full task; read it before clicking Allow, especially if the request came from content on your screen.
- Memory is written automatically, so on-screen content could influence what gets saved (memory poisoning). Writes are confined to markdown in the memory folder.
- Release builds are ad-hoc signed, not notarized. Download them only from this repository's Releases page.
