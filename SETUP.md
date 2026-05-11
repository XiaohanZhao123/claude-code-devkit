# SETUP.md — installation guide

**Audience: Claude Code (the agent), running with read/write access to
the user's `~/.claude/` directory.**

The user has cloned `claude-code-devkit` and wants you to install it into
their global Claude Code profile. Follow the steps below carefully. None
of them are destructive — every overwrite is gated on the user's
existing content being inspected first.

## Pre-flight (do these first; abort if any fails)

1. Confirm the working directory is the root of `claude-code-devkit`
   (look for `hooks/`, `skills/`, `agents/`, `SETUP.md`).
2. Confirm Claude Code is installed:
   ```bash
   command -v claude && claude --version
   ```
3. Decide which `CLAUDE_HOME` the user wants the kit installed into.
   Default: `~/.claude`. If the user runs multiple profiles (e.g.
   `~/.claude` for personal + `~/.claude-work` for work), ask which
   one and use it as `$DEST` below. Otherwise just use `~/.claude`.
4. Resolve `$DEST` to an absolute path. Confirm `$DEST` exists (it
   should — Claude Code creates it on first run).

## Step 1 — Install hooks

For each file in `hooks/`:

1. Read the source file.
2. Read `$DEST/hooks/<name>` if it exists. If a different version is
   already installed, **diff against the source and ask the user**
   whether to overwrite, skip, or merge. Don't silently overwrite a
   pre-existing hook the user may have customized.
3. Copy the source to `$DEST/hooks/<name>` and `chmod +x` it.

The 6 hooks:

| Hook | Matcher | What it does |
|---|---|---|
| `block-uv-pip.sh` | PreToolUse / Bash | Blocks `uv pip install` / `uv pip uninstall` (forces `uv add`/`uv remove` for `pyproject.toml` reproducibility) |
| `block-orchestrator-writes.sh` | PreToolUse / Bash + Edit/Write | Read-only contract for sessions with `CLAUDE_ROLE=orchestrator` — blocks Edit/Write and code-mutating Bash patterns (git commit/push/rebase, sed -i, etc.). Bypasses when called from a sub-agent (payload `agent_id` set). |
| `protect-paths.sh` | PreToolUse / Edit/Write/NotebookEdit | Blocks writes to sensitive paths (`.env`, `~/.ssh/`, etc.) |
| `protect-state-from-rm.sh` | PreToolUse / Bash | Blocks destructive `rm -rf` against PR pipeline state dirs + bare `~`/`$HOME`/`/tmp`. Allowlists worker worktree paths. |
| `session-start-git-context.sh` | SessionStart | Injects git status + branch + recent commits into session start so Claude has working-tree context immediately |
| `second-opinion-commit-gate.sh` | PreToolUse / Bash | Runs `codex review --uncommitted` on every `git commit`. Blocks on `[P0]`. Skip rules: `[skip-review]` in commit msg, `SKIP_SECOND_OPINION=1`, diff > 5000 lines, WIP branch, etc. Set `CODEX_PROFILE=<name>` in env to pin a specific codex profile. |

## Step 2 — Install skills

For each directory under `skills/`:

1. If `$DEST/skills/<name>/` exists, ask the user before overwriting.
2. Otherwise copy the entire directory tree to `$DEST/skills/<name>/`.

The 5 skills (each is one `SKILL.md` file):

- `pr-review-tick` — Agent A (PR review daemon tick)
- `pr-orch-tick` — Agent B (PR orchestrator daemon tick)
- `pr-defense-loop` — defend a PR against external review bots
- `commit-defense-loop` — defend a commit against the gate hook
- `commit-quality-pipe` — three-stage pre-commit quality pipeline

## Step 3 — Install the agent

Copy `agents/code-reviewer-opus.md` to `$DEST/agents/code-reviewer-opus.md`.
If a file with the same name exists, diff and ask before overwriting.

## Step 4 — Install statusline

Copy `statusline.py` to `$DEST/statusline.py`. Make sure `python3` is on
the user's PATH (`command -v python3`). If not, warn the user — the
statusline won't render.

## Step 5 — Merge settings.json

This is the most delicate step. **Do not overwrite** `$DEST/settings.json`
if it exists — merge instead.

1. Read `settings.example.json` from this kit.
2. Read `$DEST/settings.json` if it exists; else treat as `{}`.
3. Merge per-key:
   - `permissions.allow`, `permissions.ask`: **union** (don't dedupe
     destructively — if the user has a more specific rule than ours,
     keep both)
   - `hooks.PreToolUse`, `hooks.SessionStart`: append our hooks to any
     existing matcher entries; if no matcher entry exists, create one.
     Don't append a hook that's already registered with the same `command`.
   - `statusLine`: set if absent; ask before overwriting an existing one
   - `enabledPlugins`: union (set entries to `true`; don't touch ones
     the user has set to `false`)
   - top-level scalars (`effortLevel`, `defaultMode`, `tui`,
     `preferredNotifChannel`, etc.): set if absent; ask before changing
     an existing value
4. Write the merged file. Pretty-print with 2-space indent.

## Step 6 — Install the launcher (optional, only if user wants the PR pipeline)

Ask: "Do you want the PR review pipeline? If yes I'll install the launcher script."

If yes:

1. Resolve install dir: `~/.local/bin` if it's on PATH, else `~/bin`,
   else ask the user.
2. Copy `bin/claude-pr-pipeline-up` to that dir, `chmod +x`.
3. Check `command -v claude-pr-pipeline-up` resolves; if not, advise
   the user to add the install dir to PATH.

## Step 7 — Verify prerequisites for the PR pipeline (optional)

Only if the user wants the PR pipeline. Check each, report status:

```bash
command -v gh && gh auth status   # GitHub CLI authenticated
command -v tmux                    # tmux installed
command -v flock                   # flock installed (util-linux)
command -v codex && codex --version  # codex CLI installed
```

For `codex`: also check the user has at least one working profile in
`~/.codex/config.toml`. If they don't, point them at codex's docs and
note this kit doesn't prescribe a profile — they can use whatever
non-Claude reviewer they have access to (gpt-5, gpt-4o, etc).

## Step 8 — Summary

Print to the user:

- Where you installed each artifact
- Which steps were skipped (with reason)
- The next-steps commands they can run:
  - `claude-pr-pipeline-up --only both` to start the PR daemons in a repo
  - The PR daemon will create a `dry_run` flag the first time — Agent B
    won't actually merge until the user `rm`s it
- Where to read more: `docs/architecture.md`

## Things you should NOT do

- Don't run `claude-pr-pipeline-up` yourself as part of install. That
  spawns long-running tmux daemons; the user starts those when they're
  ready, repo-by-repo.
- Don't set up systemd services or background daemons.
- Don't modify `~/.codex/config.toml`. The user owns their codex
  profile setup.
- Don't try to install missing system packages (`tmux`, `jq`, `flock`,
  etc.) — just report what's missing and let the user install via
  their package manager.
- Don't seed `$DEST/scheduled_tasks.json` or anything the user's cron
  system depends on. The PR daemons set up their own cron on first tick.
