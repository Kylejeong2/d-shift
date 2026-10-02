# Contributing

Thanks for helping out. D-Shift is early, so issues describing real-world problems (an app whose accessibility tree is thin, a tool you want) are as valuable as code.

## Setup

```bash
git clone https://github.com/Kylejeong2/d-shift.git
cd d-shift
cp .env.example .env    # add your ANTHROPIC_API_KEY
swift run
```

Read [docs/architecture.md](docs/architecture.md) for a tour of the code.

## Before opening a PR

- `swift build` succeeds with no new warnings.
- `./scripts/test.sh` passes. Add tests for logic you change, especially anything in `ShellPolicy` (security-sensitive).
- You launched the app and exercised the change. For UI changes, include a screenshot or short recording.
- Never commit `.env`, memory, history, or screenshots containing personal data.

## Style

- Match the surrounding code. Prefer clear names over comments, and comment only the non-obvious *why*.
- No new dependencies without discussion in an issue first.
- Keep tools that can change state behind `requiresApproval(for:)`.

## Commits and PRs

Commits follow [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `build:`, `ci:`, `chore:`, with an optional scope, for example `feat(tools): add calendar lookup`.

PR descriptions use the template in `.github/pull_request_template.md`: Summary, Why, What changed, Testing.

## Releases

Versions follow [Semantic Versioning](https://semver.org). While the version is 0.x, minor bumps may include breaking changes. Changes are recorded in [CHANGELOG.md](CHANGELOG.md). Pushing a `vX.Y.Z` tag runs the Release workflow, which builds the app and publishes it with that version's changelog notes.
