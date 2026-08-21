#!/usr/bin/env bash
# Ensures an Anthropic API key is available for claude_call.sh (the Claude
# side of a Codex-orchestrated run). Checks env, then a cached file, then
# prompts interactively and validates with a real API call — same shape as
# `codex login`, since there's no local `claude` CLI to shell out to.
#
# Usage: source this file, then use $ANTHROPIC_ARENA_KEY.

set -u

ARENA_KEY_FILE="$HOME/.claude/skills/codex-arena/.anthropic_key"

_arena_validate_key() {
  local key="$1"
  local resp
  resp="$(curl -s -o /dev/null -w '%{http_code}' \
    https://api.anthropic.com/v1/messages \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')"
  [ "$resp" = "200" ]
}

ensure_anthropic_key() {
  if [ -n "${ANTHROPIC_ARENA_KEY:-}" ]; then
    return 0
  fi

  if [ -f "$ARENA_KEY_FILE" ]; then
    ANTHROPIC_ARENA_KEY="$(cat "$ARENA_KEY_FILE")"
    export ANTHROPIC_ARENA_KEY
    return 0
  fi

  echo "This run needs an Anthropic API key so Claude can act as the critic." >&2
  echo "Get one at: https://console.anthropic.com/settings/keys" >&2
  printf "Paste your ANTHROPIC_API_KEY (input hidden), or leave blank to cancel: " >&2
  read -rs KEY_INPUT
  echo "" >&2

  if [ -z "$KEY_INPUT" ]; then
    echo "no key provided — cancelling." >&2
    return 1
  fi

  echo "validating..." >&2
  if ! _arena_validate_key "$KEY_INPUT"; then
    echo "error: that key didn't validate against the Anthropic API (401/other error) — check it and try again." >&2
    return 1
  fi
  echo "validated." >&2

  printf "Remember this key for next time (saved to %s, permissions 600)? [y/N]: " "$ARENA_KEY_FILE" >&2
  read -r REMEMBER
  case "$REMEMBER" in
    [yY]|[yY][eE][sS])
      mkdir -p "$(dirname "$ARENA_KEY_FILE")"
      printf '%s' "$KEY_INPUT" > "$ARENA_KEY_FILE"
      chmod 600 "$ARENA_KEY_FILE"
      echo "saved." >&2
      ;;
  esac

  ANTHROPIC_ARENA_KEY="$KEY_INPUT"
  export ANTHROPIC_ARENA_KEY
  return 0
}
