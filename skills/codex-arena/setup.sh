#!/usr/bin/env bash
# Setup for the codex-arena Claude Code skill.
# Run this from anywhere: bash setup.sh
# Safe to re-run — every step is a check-then-act, nothing is force-overwritten
# without saying so.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.claude/skills/codex-arena"
FAIL=0

say()  { printf '%s\n' "$1"; }
ok()   { printf '  [ok] %s\n' "$1"; }
warn() { printf '  [!!] %s\n' "$1"; }

say "== codex-arena setup =="

# 1. codex CLI present?
say ""
say "1. Codex CLI"
if command -v codex >/dev/null 2>&1; then
  CODEX_VERSION_LINE="$(codex --version 2>&1)"
  ok "found: $CODEX_VERSION_LINE"
  CODEX_VERSION_NUM="$(printf '%s' "$CODEX_VERSION_LINE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)"
  if [ -n "$CODEX_VERSION_NUM" ]; then
    CV_MAJOR="${CODEX_VERSION_NUM%%.*}"
    CV_REST="${CODEX_VERSION_NUM#*.}"
    CV_MINOR="${CV_REST%%.*}"
    if [ "$CV_MAJOR" -eq 0 ] 2>/dev/null && [ "$CV_MINOR" -lt 130 ] 2>/dev/null; then
      warn "codex CLI is $CODEX_VERSION_NUM — versions below 0.130 have been reported to misbehave with --json/resume; consider 'npm install -g @openai/codex@latest'"
    fi
  fi
else
  warn "not found"
  if command -v npm >/dev/null 2>&1; then
    printf "  install it now via a global npm install (npm install -g @openai/codex)? [y/N]: "
    read -r INSTALL_ANSWER
    case "$INSTALL_ANSWER" in
      [yY]|[yY][eE][sS])
        if npm install -g @openai/codex; then
          ok "installed: $(codex --version 2>&1)"
        else
          warn "npm install failed — install codex manually, then re-run this script"
          FAIL=1
        fi
        ;;
      *)
        warn "skipped — install it yourself with: npm install -g @openai/codex"
        FAIL=1
        ;;
    esac
  else
    warn "npm not found — install Node/npm first, then re-run this script"
    FAIL=1
  fi
fi

# 2. codex auth
say ""
say "2. Codex authentication"
if command -v codex >/dev/null 2>&1; then
  LOGIN_STATUS="$(codex login status 2>&1)"
  LOGIN_EXIT=$?
  if [ "$LOGIN_EXIT" -eq 0 ]; then
    ok "$LOGIN_STATUS"
  else
    warn "not logged in ($LOGIN_STATUS)"
    warn "this step is interactive — run it yourself:"
    say ""
    say "      codex login"
    say ""
    FAIL=1
  fi
else
  warn "skipped — codex CLI isn't installed yet"
  FAIL=1
fi

# 3. skill file present at the target Claude Code looks for
say ""
say "3. Skill file"
mkdir -p "$TARGET_DIR"
if [ "$SKILL_DIR" != "$TARGET_DIR" ]; then
  if [ -f "$SKILL_DIR/SKILL.md" ]; then
    COPIED_ANY=0
    for f in SKILL.md arena.sh claude_auth.sh claude_call.sh; do
      if [ -f "$SKILL_DIR/$f" ]; then
        if [ -f "$TARGET_DIR/$f" ] && cmp -s "$SKILL_DIR/$f" "$TARGET_DIR/$f"; then
          : # already up to date
        else
          cp "$SKILL_DIR/$f" "$TARGET_DIR/$f"
          [ "${f%.sh}" != "$f" ] && chmod +x "$TARGET_DIR/$f"
          COPIED_ANY=1
        fi
      fi
    done
    if [ "$COPIED_ANY" -eq 1 ]; then
      ok "copied skill files to $TARGET_DIR"
    else
      ok "already installed and up to date at $TARGET_DIR"
    fi
  else
    warn "SKILL.md not found next to this script ($SKILL_DIR) — nothing to install"
    FAIL=1
  fi
else
  if [ -f "$TARGET_DIR/SKILL.md" ]; then
    ok "SKILL.md present at $TARGET_DIR"
  else
    warn "SKILL.md missing at $TARGET_DIR — this script should live alongside it"
    FAIL=1
  fi
fi

# 4. sanity check the file isn't empty/corrupt
if [ -f "$TARGET_DIR/SKILL.md" ]; then
  if head -1 "$TARGET_DIR/SKILL.md" | grep -q "^---$"; then
    ok "SKILL.md has valid frontmatter"
  else
    warn "SKILL.md doesn't start with '---' frontmatter — check it wasn't truncated"
    FAIL=1
  fi
fi

# 5. Anthropic credentials — OPTIONAL. Only the reversed direction
# (--evaluator claude) calls the Anthropic API; the default direction runs
# Claude locally and only shells out to codex. Never sets FAIL.
say ""
say "4. Anthropic credentials (optional — only for --evaluator claude)"
if command -v ant >/dev/null 2>&1; then
  if ant auth status >/dev/null 2>&1; then
    ok "logged in via 'ant auth' — no API key needed"
  else
    warn "the 'ant' CLI is installed but not logged in. Run:"
    say ""
    say "      ant auth login"
    say ""
    say "  (or leave it — you'll be prompted for an API key if you ever run --evaluator claude)"
  fi
else
  warn "no 'ant' CLI found. Reversed runs will prompt for an API key."
  say "  To skip keys entirely, install the Anthropic CLI and run 'ant auth login'."
fi

say ""
if [ "$FAIL" -eq 0 ]; then
  say "== all set — try: /codex-arena =="
else
  say "== setup incomplete — see [!!] lines above =="
fi
exit "$FAIL"
