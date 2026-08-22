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
  local config
  # Key goes in a private curl config file, not -H argv — argv is visible to
  # any other process on the box via `ps`, a curl config isn't.
  config="$(mktemp)" || return 1
  chmod 600 "$config"
  {
    printf 'header = "x-api-key: %s"\n' "$key"
    printf 'header = "anthropic-version: 2023-06-01"\n'
    printf 'header = "content-type: application/json"\n'
  } > "$config"
  resp="$(curl -s --connect-timeout 15 --max-time 30 -K "$config" -o /dev/null -w '%{http_code}' \
    https://api.anthropic.com/v1/messages \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')"
  rm -f "$config"
  [ "$resp" = "200" ]
}

ensure_anthropic_key() {
  if [ -n "${ANTHROPIC_ARENA_KEY:-}" ]; then
    return 0
  fi

  if [ -f "$ARENA_KEY_FILE" ] && [ ! -L "$ARENA_KEY_FILE" ]; then
    CACHED_KEY="$(cat "$ARENA_KEY_FILE")"
    if [ -n "$CACHED_KEY" ] && _arena_validate_key "$CACHED_KEY"; then
      ANTHROPIC_ARENA_KEY="$CACHED_KEY"
      export ANTHROPIC_ARENA_KEY
      return 0
    fi
    echo "cached key at $ARENA_KEY_FILE didn't validate — asking again." >&2
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
      # A symlink (or a file some other user planted/owns) must never be
      # written through — refuse instead of following it. umask 077 during
      # creation additionally closes the write-then-chmod race window.
      if [ -L "$ARENA_KEY_FILE" ] || { [ -e "$ARENA_KEY_FILE" ] && { [ ! -f "$ARENA_KEY_FILE" ] || [ ! -O "$ARENA_KEY_FILE" ]; }; }; then
        echo "error: $ARENA_KEY_FILE exists (possibly as a dangling symlink) and isn't a plain file you own — refusing to write through it. Remove it manually if you want to re-save." >&2
      else
        # umask 077 covers file creation; an existing owned file could
        # already have a looser mode (e.g. 0644), which umask alone won't
        # tighten — chmod explicitly before AND after, and check both the
        # write and the final permissions before claiming success.
        SAVE_OK=1
        [ -e "$ARENA_KEY_FILE" ] && ! chmod 600 "$ARENA_KEY_FILE" && SAVE_OK=0
        if [ "$SAVE_OK" -eq 1 ] && ( umask 077; printf '%s' "$KEY_INPUT" > "$ARENA_KEY_FILE" ); then
          if chmod 600 "$ARENA_KEY_FILE"; then
            echo "saved." >&2
          else
            echo "error: saved $ARENA_KEY_FILE but failed to set permissions to 600 — check it manually." >&2
          fi
        else
          echo "error: failed to save key to $ARENA_KEY_FILE — not cached this run." >&2
        fi
      fi
      ;;
  esac

  ANTHROPIC_ARENA_KEY="$KEY_INPUT"
  export ANTHROPIC_ARENA_KEY
  return 0
}
