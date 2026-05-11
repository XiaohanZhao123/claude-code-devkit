# CLAUDE.md — contributor notes

If you're an AI agent (Claude Code, Codex, etc.) working in this repo,
read this first.

## What this repo is

A shareable subset of one person's Claude Code config — hooks, skills,
agents, and a PR-review/fix daemon pipeline. The README is the user-facing
pitch; this file is for someone (human or agent) **modifying** the kit.

## Repo layout

```
hooks/    — bash scripts invoked by Claude Code as PreToolUse / SessionStart hooks
skills/   — SKILL.md files; each defines a slash-command + protocol
agents/   — Markdown definitions for sub-agents (loaded as user-level agents)
bin/      — launcher scripts (just `claude-pr-pipeline-up` for now)
docs/     — design docs (architecture.md is the main one)
*.example.json — settings.json templates (`.example` so install doesn't clobber)
```

## Style guide

- **Bash hooks**: `set -uo pipefail` (`-e` is too eager when grep -q is in a
  conditional). Always handle the "missing dep" case as graceful exit 0
  unless silence would defeat the hook's purpose.
- **Hook exit codes**: 0 = silent allow, 1 = advisory (stderr → user only),
  2 = block (stderr → model AND block). Get this right; the diff between
  1 and 2 is what makes a hook a "contract".
- **SKILL.md files**: front-matter is `name:` + `description:`. The
  description is what the SkillRouter matches against — make it
  trigger-phrase-heavy and unambiguous (the example skills do this well;
  match their density).
- **Don't hardcode user-specific paths.** Use `$HOME` or `~`, never a
  literal home directory. Use `${CLAUDE_HOME:-$HOME/.claude}` as the
  base for things that live in the user's Claude config dir.
- **Don't hardcode the codex profile.** Pass `${CODEX_PROFILE:+--profile "$CODEX_PROFILE"}`
  and document the env var. Different users will have different profiles
  named different things.
- **Don't hardcode a specific backend, endpoint, or wrapper binary.**
  This kit is meant to work with any Claude Code config — Anthropic
  direct, Bedrock, Vertex, an enterprise proxy, etc. If you find yourself
  writing a literal hostname, port, or vendor-specific binary name into a
  hook or skill, that's a sign you're solving your deployment's problem
  inside a shared file. Lift it to an env var (the way `CODEX_PROFILE`
  is handled in `second-opinion-commit-gate.sh`) and document the var.

## What's deliberately NOT in this repo

- **Backend / proxy infrastructure.** How you route `claude` to a model
  is your deployment choice; this kit doesn't take a position on it.
  If a PR adds a hook that depends on `localhost:<port>` or a custom
  CLI wrapper, that's out of scope — generalize it via env var or split
  it into a separate downstream config.
- **Systemd unit files / launchd plists / Docker images.** Same reason
  — those are deployment concerns, not portable kit content.
- **An install.sh.** Replaced by `SETUP.md`, which Claude Code reads and
  follows. The point: install.sh would have to handle every distro's
  python3 path, every shell's PATH-modification idiom, every existing
  `~/.claude/settings.json` shape. Claude handles all of that better
  than bash.

## Testing changes

1. **Hooks**: copy your edit to `~/.claude/hooks/<name>` and trigger the
   matched tool from a Claude Code session. Tail the session's stderr
   to see the hook's output.
2. **Skills**: drop your edit into `~/.claude/skills/<name>/SKILL.md` and
   start a fresh session — Claude re-reads skills on session start.
   Invoke via the trigger phrase from `description:`.
3. **Launcher**: `bash -n bin/claude-pr-pipeline-up` syntax-check. Then
   try `bin/claude-pr-pipeline-up --only reviewer` in a throwaway repo
   worktree.

## Commit etiquette

- One concern per commit (the second-opinion gate works better on small
  diffs).
- If a commit is intentionally exempt from the gate (e.g. a typo fix,
  generated lockfile bump), put `[skip-review]` in the message with a
  one-line rationale.
- Reference the hook/skill by name in the commit subject when relevant
  (e.g. `feat(pr-review-tick): synthetic-commit splitting for large PRs`).
