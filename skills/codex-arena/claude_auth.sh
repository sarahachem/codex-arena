#!/usr/bin/env bash
# Ensures Anthropic credentials are available for claude_call.sh (the Claude
# side of a Codex-orchestrated run).
#
# Two auth modes, tried in this order:
#   oauth   — an `ant auth login` profile. Preferred: nothing to create, paste,
#             or store, and the token is short-lived and auto-refreshed. This is
#             the real analogue of `codex login`, which didn't exist when this
#             file was first written.
#   api_key — a long-lived key from env or the cached file, prompted for
#             interactively as a fallback for users without the `ant` CLI.
#
# The active mode is exported as $ANTHROPIC_ARENA_AUTH_MODE because the two
# modes need *different request headers* (see _arena_write_auth_headers), not
# just a different secret — claude_call.sh sources this file to reuse them.
#
# Usage: source this file, call ensure_anthropic_key, then use
# _arena_write_auth_headers when building a request.

set -u

ARENA_KEY_FILE="$HOME/.claude/skills/codex-arena/.anthropic_key"
# OAuth access tokens are rejected without this beta header, and they go on
# `Authorization: Bearer`, never `x-api-key` — swapping auth modes is a header
# change, not just a credential swap.
ARENA_OAUTH_BETA="oauth-2025-04-20"

# Prints a short-lived OAuth access token on stdout. Deliberately re-run for
# every request rather than captured once: these tokens expire, and
# print-credentials refreshes them as needed, which is what makes refresh
# transparent during a long multi-round arena run. --access-token is required
# — the bare form prints the whole credentials JSON, which yields an empty
# response or an HTTP/2 error if stuffed into an Authorization header.
_arena_oauth_token() {
  local token
  token="$(ant auth print-credentials --access-token 2>/dev/null)" || return 1
  [ -n "$token" ] || return 1
  printf '%s' "$token"
}

# True when the `ant` CLI is installed AND can actually mint a token.
#
# Deliberately NOT `ant auth status`: the CLI docs are explicit that status
# "reports status only — don't script against its exit code as a health
# check". Whether a token can be produced is the question we actually care
# about, so ask that directly. This may hit the network to refresh an expired
# token, but never makes a *billed* inference call — see the note on
# anthropic_key_structurally_available below.
_arena_have_ant_oauth() {
  command -v ant >/dev/null 2>&1 || return 1
  _arena_oauth_token >/dev/null 2>&1
}

# Appends the auth headers for the ACTIVE mode to the curl config file at $1.
# Secrets go in a private curl config, never in -H argv — argv is visible to
# any other process on the box via `ps`, a curl config isn't.
_arena_write_auth_headers() {
  local config="$1"
  if [ "${ANTHROPIC_ARENA_AUTH_MODE:-api_key}" = "oauth" ]; then
    local token
    token="$(_arena_oauth_token)" || return 1
    printf 'header = "authorization: Bearer %s"\n' "$token" >> "$config"
    printf 'header = "anthropic-beta: %s"\n' "$ARENA_OAUTH_BETA" >> "$config"
  else
    [ -n "${ANTHROPIC_ARENA_KEY:-}" ] || return 1
    printf 'header = "x-api-key: %s"\n' "$ANTHROPIC_ARENA_KEY" >> "$config"
  fi
}

# Validates whatever mode/credential is currently set by making one real
# (tiny, billed) request. Callers must disclose before invoking this.
_arena_validate_current_auth() {
  local resp
  local config
  config="$(mktemp)" || return 1
  chmod 600 "$config"
  if ! _arena_write_auth_headers "$config"; then
    rm -f "$config"
    return 1
  fi
  {
    printf 'header = "anthropic-version: 2023-06-01"\n'
    printf 'header = "content-type: application/json"\n'
  } >> "$config"
  resp="$(curl -s --connect-timeout 15 --max-time 30 -K "$config" -o /dev/null -w '%{http_code}' \
    https://api.anthropic.com/v1/messages \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')"
  rm -f "$config"
  [ "$resp" = "200" ]
}

# Back-compat wrapper: validate a specific API key string.
_arena_validate_key() {
  ANTHROPIC_ARENA_AUTH_MODE=api_key ANTHROPIC_ARENA_KEY="$1" _arena_validate_current_auth
}

# Sets oauth mode and confirms it actually works. Returns 1 without side
# effects if `ant` is absent, has no active profile, or the token is rejected.
_arena_try_oauth() {
  _arena_have_ant_oauth || return 1
  if ANTHROPIC_ARENA_AUTH_MODE=oauth _arena_validate_current_auth; then
    ANTHROPIC_ARENA_AUTH_MODE=oauth
    export ANTHROPIC_ARENA_AUTH_MODE
    return 0
  fi
  return 1
}

# True if credentials look available WITHOUT any BILLED API call — env var
# set, an `ant` OAuth profile that can mint a token, or a cached file that's
# readable/owned/non-symlink/non-empty. This exists so a caller can announce
# "about to use paid credentials" BEFORE the validation call in
# try_load_anthropic_key_noninteractive() below actually runs — that
# validation call is a real (tiny) billed API request, so disclosure has to
# happen ahead of it, not after.
#
# The OAuth branch may touch the network to refresh an expired token, so this
# is not strictly offline — but a token refresh costs nothing and bills
# nothing, which is the property that actually matters here.
anthropic_key_structurally_available() {
  if [ -n "${ANTHROPIC_ARENA_KEY:-}" ]; then
    return 0
  fi
  # An `ant` OAuth profile counts: it needs no key file and no prompt, so a
  # run that finds one can proceed unattended exactly like a cached key.
  if _arena_have_ant_oauth; then
    return 0
  fi
  if [ -f "$ARENA_KEY_FILE" ] && [ ! -L "$ARENA_KEY_FILE" ] && [ -O "$ARENA_KEY_FILE" ] && [ -r "$ARENA_KEY_FILE" ] && [ -s "$ARENA_KEY_FILE" ]; then
    return 0
  fi
  return 1
}

# Loads a key from env or cache and, for a cached one, validates it — but
# NEVER prompts and NEVER falls through to interactive setup on failure,
# unlike ensure_anthropic_key(). Used to decide, before any round runs,
# whether Codex-as-evaluator mode can hand fixing to Claude (a key already
# exists AND works) or must self-fix (no usable key found) — a default,
# unattended run must never block on `read` no matter what state the cache
# is in. Sets ANTHROPIC_ARENA_KEY and returns 0 on success; returns 1 (no
# output, no side effects) on any kind of failure — missing file, unreadable,
# not owned, empty, or failing live validation.
try_load_anthropic_key_noninteractive() {
  if [ -n "${ANTHROPIC_ARENA_KEY:-}" ]; then
    return 0
  fi
  # OAuth first — it's the mode that needs no stored secret at all.
  if _arena_try_oauth; then
    return 0
  fi
  if [ ! -f "$ARENA_KEY_FILE" ] || [ -L "$ARENA_KEY_FILE" ] || [ ! -O "$ARENA_KEY_FILE" ] || [ ! -r "$ARENA_KEY_FILE" ]; then
    return 1
  fi
  local cached_key
  cached_key="$(cat "$ARENA_KEY_FILE" 2>/dev/null)" || return 1
  if [ -z "$cached_key" ] || ! _arena_validate_key "$cached_key"; then
    return 1
  fi
  ANTHROPIC_ARENA_KEY="$cached_key"
  export ANTHROPIC_ARENA_KEY
  return 0
}

ensure_anthropic_key() {
  if [ -n "${ANTHROPIC_ARENA_KEY:-}" ]; then
    return 0
  fi

  # OAuth first: no key to create, nothing written to disk by this plugin, and
  # the token refreshes itself. Only fall through to the key paths below for
  # users who don't have the `ant` CLI or an active profile.
  if _arena_try_oauth; then
    echo "using your existing Anthropic login (ant auth) — no API key needed." >&2
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

  echo "This run needs Anthropic credentials so Claude can act as the critic." >&2
  echo "" >&2
  if command -v ant >/dev/null 2>&1; then
    # `ant` is installed but had no active profile — logging in is one command
    # and avoids creating a key entirely, so lead with it.
    echo "  Recommended: run  ant auth login  in another terminal, then re-run" >&2
    echo "  this — no API key needed, and nothing gets stored by this plugin." >&2
  else
    echo "  Recommended: install the Anthropic CLI and run  ant auth login" >&2
    echo "  — no API key needed, and nothing gets stored by this plugin." >&2
  fi
  echo "" >&2
  echo "  Otherwise, paste an API key from https://console.anthropic.com/settings/keys" >&2
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
