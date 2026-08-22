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

# Build the entire request body via json.dumps, including the model name —
# never string-interpolate a variable directly into a JSON literal.
REQUEST_BODY="$(MODEL="$MODEL" python3 -c '
import json, os, sys
print(json.dumps({
    "model": os.environ["MODEL"],
    "max_tokens": 4096,
    "messages": [{"role": "user", "content": sys.stdin.read()}],
}))' < "$PROMPT_FILE")"

# The API key goes in a private curl config file, not a -H argument — args
# are visible to any other process on the box via `ps`; a curl config isn't.
CURL_CONFIG="$(mktemp)" || {
  echo "error: mktemp failed for curl config" >&2
  exit 1
}
chmod 600 "$CURL_CONFIG"
{
  printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_ARENA_KEY"
  printf 'header = "anthropic-version: 2023-06-01"\n'
  printf 'header = "content-type: application/json"\n'
} > "$CURL_CONFIG"

RESPONSE="$(curl -sS \
  --connect-timeout 15 \
  --max-time 120 \
  --retry 2 \
  --retry-connrefused \
  --retry-delay 2 \
  -K "$CURL_CONFIG" \
  -w '%{http_code}' \
  -o /dev/stdout \
  https://api.anthropic.com/v1/messages \
  -d "$REQUEST_BODY")"
CURL_STATUS=$?
rm -f "$CURL_CONFIG"

if [ "$CURL_STATUS" -ne 0 ]; then
  echo "error: curl failed to reach the Anthropic API (exit $CURL_STATUS — network error or timeout)" >&2
  exit 1
fi

# The last 3 characters are the %{http_code} appended by -w; everything before is the body.
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ -z "$BODY" ]; then
  echo "error: Anthropic API returned an empty response (HTTP $HTTP_CODE)" >&2
  exit 1
fi

PARSE_STATUS=0
ERROR_MSG="$(printf '%s' "$BODY" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except ValueError as e:
    print(f"malformed JSON response: {e}")
    sys.exit(0)
print(d.get("error",{}).get("message",""))' 2>&1)" || PARSE_STATUS=1

if [ "$PARSE_STATUS" -ne 0 ]; then
  echo "error: failed to parse Anthropic API response (HTTP $HTTP_CODE): $ERROR_MSG" >&2
  exit 1
fi
if [ -n "$ERROR_MSG" ]; then
  echo "error: Anthropic API call failed (HTTP $HTTP_CODE): $ERROR_MSG" >&2
  exit 1
fi
if [ "$HTTP_CODE" != "200" ]; then
  echo "error: Anthropic API returned HTTP $HTTP_CODE with no error message body" >&2
  exit 1
fi

TEXT_STATUS=0
TEXT="$(printf '%s' "$BODY" | python3 -c 'import json,sys
d=json.load(sys.stdin)
text = "".join(b.get("text","") for b in d.get("content",[]) if b.get("type")=="text")
print(text)')" || TEXT_STATUS=1
if [ "$TEXT_STATUS" -ne 0 ]; then
  echo "error: failed to extract text content from Anthropic API response" >&2
  exit 1
fi
if [ -z "$TEXT" ]; then
  echo "error: Anthropic API response contained no text content" >&2
  exit 1
fi
printf '%s\n' "$TEXT" > "$OUT_TEXT"

USAGE_STATUS=0
USAGE="$(printf '%s' "$BODY" | python3 -c 'import json,sys

def require_int(u, key):
    if key not in u:
        raise ValueError(f"usage missing required field {key!r}")
    val = u[key]
    if isinstance(val, bool) or not isinstance(val, int) or val < 0:
        raise ValueError(f"usage field {key!r} is not a nonnegative integer: {val!r}")
    return val

d=json.load(sys.stdin)
u=d.get("usage")
if not isinstance(u, dict):
    print("usage field missing or not an object", file=sys.stderr)
    sys.exit(1)
try:
    print(require_int(u, "input_tokens") + require_int(u, "output_tokens"))
except ValueError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)')" || USAGE_STATUS=1
if [ "$USAGE_STATUS" -ne 0 ]; then
  echo "error: Anthropic API response had no usable usage field" >&2
  exit 1
fi
printf '%s\n' "$USAGE" > "$OUT_USAGE"
