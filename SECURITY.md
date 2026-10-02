# Security Policy

D-Shift reads your screen, runs shell commands, and sends context to a third-party API, so security reports are taken seriously.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's [private vulnerability reporting](https://github.com/Kylejeong2/d-shift/security/advisories/new) instead, with steps to reproduce and the impact. You should get an acknowledgement within a few days.

## Scope

Especially interesting:

- Bypasses of `ShellPolicy`: a command that runs without approval but writes files, executes other programs, or reads outside the memory folder.
- Prompt-injection paths where on-screen content leads to an unapproved state change.
- Leakage of the API key, memory, or history outside the documented data flows.

## Known limitations

- Screen context and memory overviews are sent to the Anthropic API by design. See the Privacy section of the README.
- Approved commands run with your user's full permissions. Read the approval card before clicking Allow.
- Builds are currently unsigned and run from source.
