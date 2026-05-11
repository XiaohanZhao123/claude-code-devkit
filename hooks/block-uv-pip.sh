#!/usr/bin/env bash
# Global Claude Code PreToolUse hook (matcher: Bash).
#
# Blocks `uv pip install` / `uv pip uninstall` invocations. Those commands
# bypass pyproject.toml and uv.lock, breaking reproducibility across
# worktrees and collaborators. Always use `uv add` / `uv remove` instead.
#
# Skip rules (silently exit 0):
#   - empty / non-Bash payload
#   - SKIP_UV_PIP_GUARD=1 in env (set when launching `claude` to bypass once)

set -uo pipefail

# Allow operator-level bypass: SKIP_UV_PIP_GUARD=1 claude
if [ "${SKIP_UV_PIP_GUARD:-}" = "1" ]; then
    exit 0
fi

PAYLOAD=$(cat)

# Extract the Bash command from the hook payload using python3 (no jq dep).
COMMAND=$(printf '%s' "$PAYLOAD" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""), end="")
except Exception:
    pass
' 2>/dev/null) || COMMAND=""

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Match `uv pip install` / `uv pip uninstall` anywhere on the line, including
# after `&&`, `;`, `|`, or inside a subshell. The leading boundary is either
# start-of-string or a non-alphanumeric/underscore/dash char.
if printf '%s' "$COMMAND" | grep -qE '(^|[^[:alnum:]_-])uv[[:space:]]+pip[[:space:]]+(install|uninstall)\b'; then
    cat >&2 <<'EOF'
Blocked: `uv pip install/uninstall` bypasses pyproject.toml and uv.lock,
which breaks reproducibility across worktrees and collaborators.

Use instead:
  - `uv add <pkg>`      (instead of `uv pip install <pkg>`)
  - `uv remove <pkg>`   (instead of `uv pip uninstall <pkg>`)

If you genuinely need `uv pip` (rare — e.g. installing into a non-managed
venv), ask the user to relaunch Claude Code with SKIP_UV_PIP_GUARD=1 set
in the environment, or run the command manually outside of Claude.

(This block comes from ~/.claude/hooks/block-uv-pip.sh.)
EOF
    exit 2
fi

exit 0
