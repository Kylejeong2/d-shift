# Memory

D-Shift's memory is a folder of markdown files. There is no database and no embedding index: the model searches files with `grep` and `rg` the way you would.

## Location

Default: `~/Library/Application Support/DShift/memory`. Override with `DSHIFT_DATA_DIR` (memory goes in `$DSHIFT_DATA_DIR/memory`). It is outside the repository by default, so it can't be committed by accident. If you place it inside the repo, `data/`, `memory/`, and `history/` are git-ignored.

## Layout

On first launch D-Shift creates:

```
memory/
├── me.md        # profile: name, role, writing style, anything always relevant
├── notes.md     # dated one-line facts appended by save_memory
├── people/      # e.g. people/alex-chen.md
└── projects/    # e.g. projects/q3-launch.md
```

The layout is only a convention. Any `.md` file anywhere under `memory/` is searchable and appears in the file list.

## What the model sees

Every request includes a `<memory>` block containing:

- the full text of `me.md`
- the relative paths of all markdown files (first 200)

Everything else is fetched on demand with the `bash` tool. This keeps requests small while letting the model know what exists. Keep `me.md` short, and put details in other files.

## Searching: the bash tool

The `bash` tool runs `bash -c <command>` with the working directory set to the memory folder, a 20 second timeout, output capped at 30k characters, and `ANTHROPIC_API_KEY` removed from the environment.

Commands that pass `ShellPolicy.isReadOnlyWithinFolder` run without asking. A command passes when all of these hold:

- Every pipeline segment starts with an allowlisted read-only program: `rg grep egrep fgrep find ls cat head tail wc tree file stat`.
- It contains none of `; & \` $ < > \ ( ) { }` or newlines (no chaining, redirection, or substitution).
- No argument is an absolute path, uses `~` or `..`, or attaches a path to a flag (`-f/etc/x`, `--file=/x`).
- No command-executing or file-writing flags: `find -exec/-execdir/-ok/-okdir/-delete/-fprint*`, `rg --pre`.

Everything else shows an Allow / Deny card in the chat. This matters because the model reads your screen, and screen content can contain instructions meant to manipulate it (prompt injection). The policy is covered by `Tests/DShiftTests/ShellPolicyTests.swift`. If you change it, add cases there.

## Writing

- `save_memory` appends a dated line to `notes.md`. It always asks first.
- For structured edits (a new `people/` file, rewriting a section), the model uses `bash`, which asks first because writes never pass the read-only policy.

## Chat history

Each message is appended to `history/YYYY-MM-DD.jsonl` with a timestamp, role, text, frontmost app, and chat tab ID. History is a log for you. It is not read back into the model.
