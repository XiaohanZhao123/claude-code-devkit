#!/usr/bin/env python3
# Claude Code statusline. Reads a JSON event on stdin, prints one line to stdout.
# Format: <model> | <git branch if any> | ctx <used tokens>
#
# "Used tokens" = the prompt size of the most recent assistant turn
# (input_tokens + cache_read_input_tokens + cache_creation_input_tokens from
# the latest message.usage entry in the transcript jsonl). That equals the
# full conversation context that was last sent to the model.
import json
import os
import subprocess
import sys

try:
    event = json.load(sys.stdin)
except Exception:
    event = {}

transcript = event.get("transcript_path") or ""
model_obj = event.get("model") or {}
model_id = model_obj.get("id") or ""
model_disp = model_obj.get("display_name") or ""
cwd = event.get("cwd") or ""

# Pick the most informative model label.
# Priority:
#   1. Env override (ANTHROPIC_DEFAULT_OPUS_MODEL_NAME) — useful when you
#      route through a backend that exposes its own model IDs, and you
#      want the statusline to show the canonical "claude-opus-4.7-1m"
#      string instead of whatever the backend returns.
#   2. The id, if it carries a version marker like 4.7 / 4.6 / -1m / -xhigh
#      (some Claude Code event payloads ship a generic display_name like
#      "Opus 4" even when the actual id is more specific — the id wins).
#   3. The display_name as-given.
#   4. "claude" as last-ditch fallback.
override = os.environ.get("ANTHROPIC_DEFAULT_OPUS_MODEL_NAME") or ""
if override:
    model = override
elif model_id and any(t in model_id for t in ("4.7", "4.6", "4.5", "-1m", "-high", "-xhigh")):
    model = model_id
else:
    model = model_disp or model_id or "claude"

used = None
if transcript and os.path.isfile(transcript):
    try:
        with open(transcript, "rb") as f:
            for raw in reversed(f.readlines()):
                try:
                    d = json.loads(raw)
                except Exception:
                    continue
                msg = d.get("message")
                if isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
                    u = msg["usage"]
                    used = (u.get("input_tokens", 0) or 0) \
                         + (u.get("cache_read_input_tokens", 0) or 0) \
                         + (u.get("cache_creation_input_tokens", 0) or 0)
                    break
    except Exception:
        pass

def fmt(n):
    if n is None: return None
    if n < 1000: return f"{n}"
    if n < 1_000_000: return f"{n/1000:.1f}k"
    return f"{n/1_000_000:.2f}M"

branch = ""
if cwd and os.path.isdir(cwd):
    try:
        branch = subprocess.run(
            ["git", "-C", cwd, "branch", "--show-current"],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
    except Exception:
        pass

parts = [model]
if branch:
    parts.append(branch)
if used is not None:
    parts.append(f"ctx {fmt(used)}")

print(" | ".join(parts))
