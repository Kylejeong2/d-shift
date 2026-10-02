# Memory

D-Shift's memory is a folder of markdown files. There is no database and no embedding index: the model searches files with `grep` and `rg` the way you would.

## Location

Default: `~/Library/Application Support/DShift/memory`. Override with `DSHIFT_DATA_DIR` (memory goes in `$DSHIFT_DATA_DIR/memory`). It is outside the repository by default, so it can't be committed by accident. If you place it inside the repo, `data/`, `memory/`, and `history/` are git-ignored.

## Layout

On first launch D-Shift creates:

```
memory/
├── me.md        # profile: name, role, writing style, anything always relevant
├── notes.md     # small facts
├── people/      # e.g. people/alex-chen.md
└── projects/    # e.g. projects/q3-launch.md
```

The layout is only a convention. Any `.md` file anywhere under `memory/` is searchable and appears in the file list.

## What the model sees

Every request includes a `<memory>` block containing:

- the full text of `me.md`
- the relative paths of all markdown files (first 200)

Everything else is fetched on demand with `search_memory`. This keeps requests small while letting the model know what exists. Keep `me.md` short, and put details in other files.

## Background tools

Both memory tools are hidden: they run without a card in the chat, and the system prompt tells the model not to mention memory unless asked. You see the effect, not the plumbing.

## Searching: search_memory

`search_memory` runs `bash -c <command>` with the working directory set to the memory folder, a 20 second timeout, output capped at 30k characters, and `ANTHROPIC_API_KEY` removed from the environment.

It only runs commands that pass `ShellPolicy.isReadOnlyWithinFolder`. Anything else is refused and the model gets an error, because there is no visible approval step to escalate to. A command passes when all of these hold:

- Every pipeline segment starts with an allowlisted read-only program: `rg grep egrep fgrep find ls cat head tail wc tree file stat`.
- It contains none of `; & \` $ < > \ ( ) { }` or newlines (no chaining, redirection, or substitution).
- No argument is an absolute path, uses `~` or `..`, or attaches a path to a flag (`-f/etc/x`, `--file=/x`).
- No command-executing or file-writing flags: `find -exec/-execdir/-ok/-okdir/-delete/-fprint*`, `rg --pre`.

This matters because the model reads your screen, and screen content can contain instructions meant to manipulate it (prompt injection). The policy is covered by `Tests/DShiftTests/ShellPolicyTests.swift`. If you change it, add cases there.

## Writing

`write_memory` takes a relative `path`, `content`, and a `mode` of `append` (default) or `replace`. It creates folders as needed. `MemoryPath.resolve` rejects absolute paths, `~`, anything that escapes the folder (including through symlinks), and non-`.md` files. That logic is covered by `Tests/DShiftTests/MemoryPathTests.swift`.

The model saves durable facts without asking: people go in `people/<name>.md`, projects in `projects/<name>.md`, your profile in `me.md`, and small facts in `notes.md`. It is told not to save transient details, secrets, or anything you ask it not to keep. To correct or remove something, edit the files directly.

## Chat history

Each message is appended to `history/YYYY-MM-DD.jsonl` with a timestamp, role, text, frontmost app, and chat tab ID. History is a log for you. It is not read back into the model.
