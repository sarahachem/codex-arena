#!/usr/bin/env bash
# claude_call.sh — one Anthropic API turn, used as the Claude side of a
# Codex-orchestrated arena run. Analogous to one `codex exec` call: takes a
# prompt, returns the model's text and token usage. Read-only by nature —
# this is a plain chat completion, it has no tool access and cannot touch
# the filesystem, so there's no sandbox flag to get right the way codex
# needed one.
#
# Usage: claude_call.sh <prompt-file> <output-text-file> <output-usage-file>
# Requires: claude_auth.sh sourced first, ANTHROPIC_ARENA_KEY set.

set -u

PROMPT_FILE="$1"
OUT_TEXT="$2"
OUT_USAGE="$3"
MODEL="${ANTHROPIC_ARENA_MODEL:-claude-sonnet-5}"

if [ -z "${ANTHROPIC_ARENA_KEY:-}" ]; then
  echo "error: ANTHROPIC_ARENA_KEY not set — run claude_auth.sh's ensure_anthropic_key first" >&2
  exit 1
fi

PROMPT_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < "$PROMPT_FILE")"

RESPONSE="$(curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_ARENA_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "'"$MODEL"'",
    "max_tokens": 4096,
    "messages": [{"role": "user", "content": '"$PROMPT_JSON"'}]
  }')"

ERROR_MSG="$(echo "$RESPONSE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("error",{}).get("message",""))' 2>/dev/null)"
if [ -n "$ERROR_MSG" ]; then
  echo "error: Anthropic API call failed: $ERROR_MSG" >&2
  exit 1
fi

echo "$RESPONSE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
text = "".join(b.get("text","") for b in d.get("content",[]) if b.get("type")=="text")
print(text)' > "$OUT_TEXT"

echo "$RESPONSE" | python3 -c 'import json,sys
d=json.load(sys.stdin)
u=d.get("usage",{})
print((u.get("input_tokens",0) or 0) + (u.get("output_tokens",0) or 0))' > "$OUT_USAGE"
