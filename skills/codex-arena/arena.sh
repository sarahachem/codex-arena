#!/usr/bin/env bash
# codex-arena — standalone adversarial review runner.
#
# Runs the full review conversation automatically: Codex critiques the
# artifact (read-only, every round) and proposes a corrected version as
# TEXT — never a file write. Each round after the first re-reviews that
# proposal as a hypothetical ("if this replaced the file, would it pass?"),
# refining it, until Codex approves it, nothing new is proposed, or a
# round/token budget runs out. Codex NEVER gets write access, at any point.
#
# Only at the end — once there's a final candidate — does the script ask
# YOU, once, whether to actually write it to the real file. If you say yes,
# the SCRIPT does the write, in plain bash. Codex never touches the
# filesystem, ever, in any round.
#
# Usage:
#   arena.sh --init --artifact FILE [--out BRIEF_FILE] [--no-run]
#     Interactive: prompts you to pick an artifact type (dataset / diff /
#     plan / config / other) and type criteria in plain English, writes a
#     brief file, then runs the full conversation automatically unless
#     --no-run is given.
#
#   arena.sh --artifact FILE --brief FILE [--max-rounds N] [--max-tokens N] [--resume THREAD_ID]
#     Runs the full conversation using an existing brief file.
#
#   --evaluator codex (default): Codex critiques an existing artifact. Who fixes
#     it depends on whether an Anthropic API key is already available — checked
#     silently, no prompt, no billed action just from checking:
#       - No key found anywhere (env var, or the cache at
#         ~/.claude/skills/codex-arena/.anthropic_key): Codex is the only model
#         reachable in this unattended script, so it judges AND writes its own
#         fix, self-reviewed round after round. This is the plain free default.
#       - A key IS found: Codex becomes evaluator-only — it critiques but never
#         writes the accepted fix. Claude (via that key, the same paid path
#         --evaluator claude uses) either writes its own corrected version each
#         round (Codex's own proposed fix is shown to Claude only as
#         non-authoritative context) or disputes the finding, putting the
#         specific objection back to Codex to withdraw or defend.
#     The interactive "paste your key" setup (via claude_auth.sh) never runs
#     from this path — only --evaluator claude below triggers that the first
#     time. Once a key exists (env var, or cached from a prior --evaluator
#     claude run), every subsequent --evaluator codex run picks it up
#     automatically. Ask before assuming the user wants a key set up at all —
#     it's a genuinely separate, billed API path, not part of any Claude
#     Code/Claude.ai subscription.
#   --evaluator claude: reversed — Codex BUILDS (via codex exec, still read-only,
#     text-only), Claude EVALUATES via a direct Anthropic API call. Needs a real
#     ANTHROPIC_API_KEY — prompted for interactively on first use (via
#     claude_auth.sh) and cached at ~/.claude/skills/codex-arena/.anthropic_key
#     if you opt in. This is a genuinely separate, billed API path — not part
#     of any Claude Code/Claude.ai subscription. Ask before assuming the user
#     wants to set this up; it costs real money on its own account.
#
# Exit codes: 0 = converged/approved, 1 = stopped without approval
#             (round/token limit, or nothing left to propose), 2 = setup
#             error, 3 = a codex or claude call failed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARTIFACT=""
BRIEF=""
THREAD_ID=""
MAX_TOKENS=250000
MAX_ROUNDS=3
STATE_DIR="${CODEX_ARENA_STATE_DIR:-}"
INIT_MODE=0
INIT_OUT=""
NO_RUN=0
EVALUATOR="codex"
API_ARBITER=0

BEGIN_MARK="===BEGIN_PROPOSED_ARTIFACT==="
END_MARK="===END_PROPOSED_ARTIFACT==="

while [ $# -gt 0 ]; do
  case "$1" in
    --init) INIT_MODE=1; shift ;;
    --no-run) NO_RUN=1; shift ;;
    --api-arbiter)
      echo "error: --api-arbiter was removed — --evaluator codex now auto-detects an available Anthropic key (env var or cache) and uses it the same way; just omit the flag" >&2
      exit 2
      ;;
    --out|--artifact|--brief|--resume|--max-rounds|--max-tokens|--evaluator)
      if [ $# -lt 2 ]; then
        echo "error: $1 requires a value" >&2
        exit 2
      fi
      FLAG="$1"; VAL="$2"
      case "$FLAG" in
        --out) INIT_OUT="$VAL" ;;
        --artifact) ARTIFACT="$VAL" ;;
        --brief) BRIEF="$VAL" ;;
        --resume) THREAD_ID="$VAL" ;;
        --max-rounds) MAX_ROUNDS="$VAL" ;;
        --max-tokens) MAX_TOKENS="$VAL" ;;
        --evaluator) EVALUATOR="$VAL" ;;
      esac
      shift 2
      ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$EVALUATOR" in
  codex|claude) ;;
  *) echo "error: --evaluator must be 'codex' (default) or 'claude'" >&2; exit 2 ;;
esac

require_positive_int() {
  # Canonical decimal integer only (no leading zeros, no leading '+'), and
  # bounded well under bash's 64-bit arithmetic range to avoid overflow.
  case "$1" in
    ''|0|*[!0-9]*|0[0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 9 ]
}
if ! require_positive_int "$MAX_ROUNDS"; then
  echo "error: --max-rounds must be a positive integer (no leading zeros, <=9 digits), got '$MAX_ROUNDS'" >&2
  exit 2
fi
if ! require_positive_int "$MAX_TOKENS"; then
  echo "error: --max-tokens must be a positive integer (no leading zeros, <=9 digits), got '$MAX_TOKENS'" >&2
  exit 2
fi

# ---------------------------------------------------------------- init ----
if [ "$INIT_MODE" -eq 1 ]; then
  if [ -z "$ARTIFACT" ]; then
    echo "error: --init requires --artifact FILE" >&2
    exit 2
  fi
  if [ ! -f "$ARTIFACT" ]; then
    echo "error: artifact not found: $ARTIFACT" >&2
    exit 2
  fi
  OUT="${INIT_OUT:-$(dirname "$ARTIFACT")/ARENA-BRIEF.md}"

  echo "Artifact: $ARTIFACT"
  echo ""
  echo "What kind of artifact is this? (same table as the codex-arena skill's Setup step 2)"
  echo "  1) Synthetic / eval dataset"
  echo "  2) Diff / patch"
  echo "  3) Implementation plan"
  echo "  4) Config file"
  echo "  5) Something else / none of these"
  printf "Pick 1-5: "
  read -r TYPE_PICK

  GUESS_TYPE=""
  DEFAULTS=""
  case "$TYPE_PICK" in
    1)
      GUESS_TYPE="synthetic / eval dataset"
      DEFAULTS="- Schema/format validity per row
- Exact and near-duplicate rows
- Label or answer correctness for the given input
- Missing or malformed fields
- Class/category imbalance worth flagging
- Adversarial or edge-case coverage gaps" ;;
    2)
      GUESS_TYPE="diff / patch"
      DEFAULTS="- Correctness against stated intent
- Security issues (injection, unsafe input handling, secrets)
- Race conditions or concurrency bugs
- Missing edge cases
- Unnecessary complexity or a simpler alternative
- Consistency with existing patterns in the surrounding code" ;;
    3)
      GUESS_TYPE="implementation plan"
      DEFAULTS="- Security holes
- Race conditions
- Missing edge cases
- Schema or data-model conflicts
- Wrong assumptions the plan rests on
- Observability gaps
- A simpler approach that was overlooked" ;;
    4)
      GUESS_TYPE="config file"
      DEFAULTS="- Values inconsistent with what's declared elsewhere in the repo
- Insecure defaults
- Missing required keys
- Typos that would silently no-op instead of erroring" ;;
    *)
      GUESS_TYPE="" ;;
  esac

  echo ""
  if [ -n "$GUESS_TYPE" ]; then
    echo "Default checks for $GUESS_TYPE:"
    echo "$DEFAULTS"
    echo ""
    echo "Type anything to add or override — your text is appended below the defaults and told"
    echo "to take priority if it conflicts with one (e.g. \"don't flag X\" overrides a default that"
    echo "would). The defaults themselves are never deleted from the brief, only outweighed. Or"
    echo "just press enter on an empty first line to use the defaults above as-is. Finish with an"
    echo "empty line."
  else
    echo "In plain English: what should this be checked against? What counts as wrong?"
    echo "(one or more lines; finish with an empty line)"
  fi
  CRITERIA_TEXT=""
  while IFS= read -r LINE; do
    [ -z "$LINE" ] && break
    CRITERIA_TEXT="${CRITERIA_TEXT}${LINE}
"
  done

  if [ -z "$CRITERIA_TEXT" ] && [ -z "$DEFAULTS" ]; then
    echo "error: no criteria entered — nothing written" >&2
    exit 2
  fi

  {
    echo "# Arena Review: $ARTIFACT"
    echo ""
    echo "You are an adversarial reviewer. Be skeptical and specific — your job is to find what's"
    echo "wrong, not to be agreeable."
    echo ""
    if [ -n "$DEFAULTS" ]; then
      echo "## Default checks ($GUESS_TYPE)"
      echo "$DEFAULTS"
      echo ""
    fi
    if [ -n "$CRITERIA_TEXT" ] && [ -n "$DEFAULTS" ]; then
      echo "## Additional checks (user-specified — these take priority over the defaults above)"
      echo "$CRITERIA_TEXT"
    elif [ -n "$CRITERIA_TEXT" ]; then
      echo "## What to check"
      echo "$CRITERIA_TEXT"
    fi
    echo "## Verdict"
    echo "End with exactly one line: RESULT: PASS if it's sound, or RESULT: FAIL if there's a material problem."
    echo ""
    echo "## Proposed fix (only if FAIL)"
    echo "If — and only if — you find a material problem, also propose a corrected version of the"
    echo "full artifact content that would resolve it. Wrap it EXACTLY like this, nothing else inside:"
    echo "$BEGIN_MARK"
    echo "<full corrected content of the artifact>"
    echo "$END_MARK"
  } > "$OUT"

  echo ""
  echo "wrote: $OUT"

  if [ "$NO_RUN" -eq 1 ]; then
    echo ""
    echo "to run: $0 --artifact \"$ARTIFACT\" --brief \"$OUT\""
    exit 0
  fi

  BRIEF="$OUT"
  echo ""
fi

# --------------------------------------------------------------- setup ----
if [ -z "$ARTIFACT" ] || [ -z "$BRIEF" ]; then
  echo "error: --artifact and --brief are required (or use --init to create a brief first)" >&2
  exit 2
fi
if [ ! -f "$ARTIFACT" ]; then
  echo "error: artifact not found: $ARTIFACT" >&2
  exit 2
fi
if [ ! -f "$BRIEF" ]; then
  echo "error: brief not found: $BRIEF" >&2
  exit 2
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex CLI not found — run setup.sh first" >&2
  exit 2
fi
# Soft version floor, not a hard block — 0.130 is the floor other Codex CLI
# review tooling (Crucible/grill-me-codex) has documented as needed for
# reliable --json/resume behavior; a warning rather than an error since we
# haven't independently confirmed our own exact minimum.
CODEX_VERSION_LINE="$(codex --version 2>&1)"
CODEX_VERSION_NUM="$(printf '%s' "$CODEX_VERSION_LINE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1)"
if [ -n "$CODEX_VERSION_NUM" ]; then
  CV_MAJOR="${CODEX_VERSION_NUM%%.*}"
  CV_REST="${CODEX_VERSION_NUM#*.}"
  CV_MINOR="${CV_REST%%.*}"
  if [ "$CV_MAJOR" -eq 0 ] 2>/dev/null && [ "$CV_MINOR" -lt 130 ] 2>/dev/null; then
    echo "warning: codex CLI is $CODEX_VERSION_NUM — versions below 0.130 have been reported to misbehave with --json/resume; consider 'npm install -g @openai/codex@latest' if this run acts up" >&2
  fi
fi

if [ "$EVALUATOR" = "claude" ]; then
  if [ ! -f "$SCRIPT_DIR/claude_auth.sh" ] || [ ! -f "$SCRIPT_DIR/claude_call.sh" ]; then
    echo "error: --evaluator claude needs claude_auth.sh and claude_call.sh next to this script" >&2
    exit 2
  fi
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/claude_auth.sh"
  if ! ensure_anthropic_key; then
    echo "error: no Anthropic API key — can't run --evaluator claude without one" >&2
    exit 2
  fi
  echo "evaluator: claude (Codex builds, Claude evaluates via direct API call)"
else
  # --evaluator codex (default): auto-detect, don't prompt. A key already
  # available (env var, or a previously cached/validated file — see
  # claude_auth.sh) means Claude can act as evaluator-only's fixer for free
  # (no new billed action triggered by this check itself); no key anywhere
  # means Codex is the only model reachable and must judge and fix itself.
  # Never prompts here — that would make a plain default run interactive,
  # breaking unattended use; the interactive "paste your key" flow only ever
  # runs the first time you explicitly use --evaluator claude.
  if [ -f "$SCRIPT_DIR/claude_auth.sh" ] && [ -f "$SCRIPT_DIR/claude_call.sh" ]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/claude_auth.sh"
    # Structural check first (no network call) so the billing notice can be
    # printed BEFORE the validation call below — which is itself a real, tiny
    # billed Anthropic request. Disclosure has to happen ahead of that call,
    # not after it.
    if anthropic_key_structurally_available; then
      echo "NOTE: an Anthropic API key appears to be available — if it validates, this run will make billed Anthropic API calls whenever Codex flags a problem (Codex only judges, Claude fixes). Not covered by any Claude Code/Claude.ai subscription. Ctrl-C now if that's not wanted; unset ANTHROPIC_ARENA_KEY or remove $ARENA_KEY_FILE to force free self-fix mode instead." >&2
      # Loads AND validates in one non-interactive step — never falls through
      # to `read` on an invalid key the way ensure_anthropic_key() would.
      if try_load_anthropic_key_noninteractive; then
        API_ARBITER=1
      else
        echo "NOTE: that key didn't validate — continuing in free self-fix mode instead." >&2
      fi
    fi
  fi
  if [ "$API_ARBITER" -eq 1 ]; then
    echo "evaluator: codex, with Claude fixing (Anthropic API key validated — Codex only judges, Claude writes every accepted fix or disputes the finding back to Codex)"
  else
    echo "evaluator: codex (no Anthropic API key found — Codex judges and fixes itself, read-only every round)"
  fi
fi

if [ -z "$STATE_DIR" ]; then
  # No explicit state dir: make a private, unpredictable one per run. A resumed
  # run (--resume THREAD_ID) needs the SAME dir across invocations — pass
  # CODEX_ARENA_STATE_DIR explicitly for that, don't rely on the default.
  STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-arena.XXXXXXXXXX")" || {
    echo "error: mktemp failed to create a state directory" >&2
    exit 2
  }
else
  if [ -e "$STATE_DIR" ]; then
    if [ ! -d "$STATE_DIR" ] || [ -L "$STATE_DIR" ] || [ ! -O "$STATE_DIR" ]; then
      echo "error: CODEX_ARENA_STATE_DIR exists but isn't a plain directory you own, refusing to use it: $STATE_DIR" >&2
      exit 2
    fi
  else
    mkdir -p "$STATE_DIR" || {
      echo "error: failed to create state directory: $STATE_DIR" >&2
      exit 2
    }
  fi
fi
if [ -L "$STATE_DIR" ]; then
  echo "error: state dir is a symlink, refusing to use it: $STATE_DIR" >&2
  exit 2
fi
if ! chmod 700 "$STATE_DIR"; then
  echo "error: failed to set permissions on state directory: $STATE_DIR" >&2
  exit 2
fi
SLUG="$(basename "$ARTIFACT" | tr -c 'a-zA-Z0-9' '-')"
VERDICT_FILE="$STATE_DIR/${SLUG}-verdict.txt"
RAW_FILE="$STATE_DIR/${SLUG}-raw.jsonl"
LOG_FILE="$STATE_DIR/${SLUG}-tokens.log"
CANDIDATE_FILE="$STATE_DIR/${SLUG}-candidate.txt"
CLAUDE_PROMPT_FILE="$STATE_DIR/${SLUG}-claude-prompt.txt"
CLAUDE_OUT="$STATE_DIR/${SLUG}-claude-out.txt"
CLAUDE_USAGE="$STATE_DIR/${SLUG}-claude-usage.txt"
# Full round-by-round record (verdict text, tokens, outcome) — LOG_FILE above
# is numbers-only and exists for the running-total calc; this is the actual
# auditable trail, since VERDICT_FILE itself gets overwritten every round.
AUDIT_LOG_FILE="$(dirname "$ARTIFACT")/$(basename "$ARTIFACT").arena-log.md"

# A pre-existing STATE_DIR (via CODEX_ARENA_STATE_DIR) is now verified to be a
# real, owned directory, but files already inside it could still be symlinks
# or pre-placed owned/hardlinked files planted before this run. Refuse rather
# than write/append through any of them — resuming a THREAD_ID intentionally
# reuses LOG_FILE across invocations, so this only rejects things that are NOT
# a plain regular file owned by the current user (a legitimate prior run's
# output passes; a symlink, device file, or someone else's file does not).
for f in "$VERDICT_FILE" "$RAW_FILE" "$LOG_FILE" "$CANDIDATE_FILE" "$CLAUDE_PROMPT_FILE" "$CLAUDE_OUT" "$CLAUDE_USAGE" "$AUDIT_LOG_FILE"; do
  if [ -L "$f" ]; then
    echo "error: $f already exists as a symlink (possibly dangling), refusing to use it" >&2
    exit 2
  fi
  if [ -e "$f" ] && { [ ! -f "$f" ] || [ ! -O "$f" ]; }; then
    echo "error: $f already exists and isn't a plain file you own, refusing to use it" >&2
    exit 2
  fi
done

# reset per-invocation logs unless resuming a prior thread
if [ -z "$THREAD_ID" ]; then
  : > "$LOG_FILE" || {
    echo "error: failed to write token log at $LOG_FILE" >&2
    exit 2
  }
  {
    echo "# Arena log: $ARTIFACT"
    echo ""
    echo "- evaluator: $EVALUATOR"
    echo "- fixer: $( [ "$EVALUATOR" = "claude" ] && echo codex || { [ "$API_ARBITER" -eq 1 ] && echo "claude (API key found)" || echo "codex (no API key found)"; } )"
    echo "- budget: max $MAX_ROUNDS rounds, max $MAX_TOKENS tokens"
    echo "- started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } > "$AUDIT_LOG_FILE" || {
    echo "error: failed to create audit log at $AUDIT_LOG_FILE — refusing to run without it" >&2
    exit 2
  }
fi
# A --resume run reuses the prior audit log, but if it's missing (state dir
# wiped, first-time resume into a fresh dir, etc.) there'd be nothing for the
# EXIT trap below to write to — make sure the file exists either way before
# the trap is installed.
if [ ! -e "$AUDIT_LOG_FILE" ]; then
  : > "$AUDIT_LOG_FILE" || {
    echo "error: failed to create audit log at $AUDIT_LOG_FILE — refusing to run without it" >&2
    exit 2
  }
fi
# An existing file can be present, owned, and a regular file, yet still not
# writable (permissions changed since last run) — a checked no-op append
# proves write access up front, the same way missing-file creation does.
: >> "$AUDIT_LOG_FILE" || {
  echo "error: audit log at $AUDIT_LOG_FILE exists but isn't writable — refusing to run without it" >&2
  exit 2
}
rm -f "$CANDIDATE_FILE"

# Every exit path from here on — success, budget/round stop, or a hard
# `exit 3` failure mid-round — must leave a record. The normal Wrap-up path
# sets AUDIT_FINALIZED=1 after writing its own "## Outcome" section; this
# trap only fires the fallback note when that never happened (an error exit
# that bypassed the summary), so failures aren't silently missing from the log.
AUDIT_FINALIZED=0
audit_finalize_on_exit() {
  local code=$?
  if [ "$AUDIT_FINALIZED" -eq 0 ] && [ -w "$AUDIT_LOG_FILE" ]; then
    {
      echo "## Run ended abnormally"
      echo ""
      echo "- exit code: $code"
      echo "- ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "- last round reached: ${ROUND:-unknown}"
    } >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2
  fi
}
trap audit_finalize_on_exit EXIT

TOTAL_SPENT=0
if [ -f "$LOG_FILE" ]; then
  TOTAL_SPENT="$(awk '{sum+=$1} END{print sum+0}' "$LOG_FILE")"
fi

extract_proposal() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b {inblock=1; next}
    $0==e {inblock=0; next}
    inblock {print}
  ' "$1"
}

# Only the exact final non-blank line counts as the verdict — a critique that
# merely mentions "RESULT: PASS" mid-text (or artifact content that does)
# must not be read as approval.
last_line_is_pass() {
  awk 'NF{line=$0} END{exit !(line=="RESULT: PASS" || line=="VERDICT: APPROVED")}' "$1"
}

last_line_is_arbiter_agree() {
  awk 'NF{line=$0} END{exit !(line=="ARBITER: AGREE")}' "$1"
}

last_line_is_arbiter_dispute() {
  awk 'NF{line=$0} END{exit !(line=="ARBITER: DISPUTE")}' "$1"
}

# Extract the thread.started thread_id via proper JSON parsing (not a regex
# that assumes exact field order/adjacency/formatting) — fails closed with no
# output if the event is missing or malformed, same discipline as
# sum_codex_usage() below.
extract_thread_id() {
  python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if ev.get("type") == "thread.started":
        tid = ev.get("thread_id")
        if isinstance(tid, str) and tid:
            print(tid)
            sys.exit(0)
sys.exit(1)
' < "$1"
}

# Sum input_tokens+output_tokens from every turn.completed event in a codex
# --json stream. Uses python3's json module (already a hard dependency via
# claude_call.sh) instead of grep/awk field-order assumptions, and fails
# closed — malformed/absent usage is an error, not a silent zero.
sum_codex_usage() {
  python3 -c '
import json, sys

def require_int(usage, key):
    if key not in usage:
        raise ValueError(f"usage missing required field {key!r}")
    val = usage[key]
    if isinstance(val, bool) or not isinstance(val, int) or val < 0:
        raise ValueError(f"usage field {key!r} is not a nonnegative integer: {val!r}")
    return val

total = 0
found = False
for lineno, line in enumerate(sys.stdin, 1):
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError as e:
        print(f"error: malformed JSON on line {lineno} of codex output: {e}", file=sys.stderr)
        sys.exit(1)
    if ev.get("type") == "turn.completed":
        usage = ev.get("usage")
        if not isinstance(usage, dict):
            print(f"error: turn.completed on line {lineno} has no usage object", file=sys.stderr)
            sys.exit(1)
        try:
            total += require_int(usage, "input_tokens") + require_int(usage, "output_tokens")
        except ValueError as e:
            print(f"error: line {lineno}: {e}", file=sys.stderr)
            sys.exit(1)
        found = True
if not found:
    print("error: no turn.completed usage event found in codex output", file=sys.stderr)
    sys.exit(1)
print(total)
' < "$1"
}

CODEX_TIMEOUT_SECONDS=600

# Runs `codex exec [resume THREAD_ID] ... -` with PROMPT_TEXT piped via a
# private temp file on stdin, instead of embedding it as a shell argument —
# avoids ARG_MAX on large artifacts/candidates and avoids the prompt ever
# appearing in `ps` output. Caller sets PROMPT_TEXT and CODEX_ARGS (array)
# before calling; result status is in CODEX_STATUS. Bounded by
# CODEX_TIMEOUT_SECONDS so a genuine stall fails visibly instead of hanging
# indefinitely — macOS has no `timeout`/`gtimeout` by default, so this is
# done by hand: background the call, poll, kill it if it outlives the budget.
run_codex() {
  local prompt_file
  prompt_file="$(mktemp "${STATE_DIR}/prompt.XXXXXXXXXX")" || {
    echo "error: mktemp failed for prompt temp file" >&2
    exit 3
  }
  printf '%s' "$PROMPT_TEXT" > "$prompt_file"

  codex exec "${CODEX_ARGS[@]}" - \
    < "$prompt_file" 2>/dev/null > "$RAW_FILE" &
  local codex_pid=$!
  local waited=0
  while kill -0 "$codex_pid" 2>/dev/null; do
    if [ "$waited" -ge "$CODEX_TIMEOUT_SECONDS" ]; then
      echo "error: codex exec exceeded ${CODEX_TIMEOUT_SECONDS}s, killing it" >&2
      kill -TERM "$codex_pid" 2>/dev/null
      sleep 2
      kill -KILL "$codex_pid" 2>/dev/null
      wait "$codex_pid" 2>/dev/null
      CODEX_STATUS=124
      rm -f "$prompt_file"
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$codex_pid"
  CODEX_STATUS=$?
  rm -f "$prompt_file"
}

# ---------------------------------------------------------- round loop ----
ROUND=1
CANDIDATE=""
OUTCOME=""
PENDING_OBJECTION=""
# Tracks whatever content Codex is actually reviewing THIS round — the real
# artifact on the opening round, the hypothetical candidate afterward — so
# the API arbiter (if enabled) judges Codex's finding against the same thing
# Codex was looking at, not always the unchanged file on disk.
REVIEWED_CONTENT=""

if [ "$EVALUATOR" = "codex" ]; then
  while true; do
    rm -f "$VERDICT_FILE" "$RAW_FILE"
    if [ -z "$THREAD_ID" ]; then
      echo "== round $ROUND (new session) =="
      PROMPT_TEXT="$(cat "$BRIEF")"
      REVIEWED_CONTENT="$(cat "$ARTIFACT")"
      CODEX_ARGS=(-s read-only --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      NEW_THREAD="$(extract_thread_id "$RAW_FILE")"
      if [ "$CODEX_STATUS" -ne 0 ] || [ -z "$NEW_THREAD" ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex call failed (exit $CODEX_STATUS) — check auth (codex login status) and model config" >&2
        exit 3
      fi
      THREAD_ID="$NEW_THREAD"
    elif [ -n "$PENDING_OBJECTION" ]; then
      echo "== round $ROUND (resuming $THREAD_ID — putting the API arbiter's objection to Codex) =="
      PROMPT_TEXT="The API arbiter reviewed your last finding and disputed it:

$PENDING_OBJECTION

Either withdraw the disputed point (say so explicitly) or defend it with a concrete reason grounded
in the same content you just reviewed in your last message in this thread — whichever that was (the
real file, or the hypothetical candidate you were re-checking) — don't switch to re-reading the
on-disk file if you were actually reviewing a candidate, and don't just restate the original finding.
Then give a fresh verdict against the full brief and criteria, in the same format as before, including
a corrected-version proposal if problems (including any you're still defending) remain."
      CODEX_ARGS=(resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      PENDING_OBJECTION=""
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    elif [ -n "$CANDIDATE" ]; then
      echo "== round $ROUND (resuming $THREAD_ID — reviewing a candidate fix as a hypothetical) =="
      REVIEWED_CONTENT="$CANDIDATE"
      PROMPT_TEXT="Here is a candidate revision$( [ "$API_ARBITER" -eq 1 ] && echo " (written independently, not necessarily matching what you proposed)" ). This has NOT been
written to the real file — it is purely hypothetical, for you to re-review as if it replaced
$ARTIFACT. Check it against the same brief and criteria as before.

$BEGIN_MARK
$CANDIDATE
$END_MARK

If this fully resolves everything, respond with the same PASS verdict format as before and
omit the proposal block. If problems remain, describe them and propose an updated corrected
version using the same $BEGIN_MARK / $END_MARK markers."
      CODEX_ARGS=(resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    else
      echo "== round $ROUND (resuming $THREAD_ID) =="
      REVIEWED_CONTENT="$(cat "$ARTIFACT")"
      PROMPT_TEXT="Re-check $ARTIFACT against the same brief and criteria. End with the same exact verdict format as before."
      CODEX_ARGS=(resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    fi

    if ! ROUND_TOKENS="$(sum_codex_usage "$RAW_FILE")"; then
      echo "error: couldn't determine round token usage from codex output — treating as a failed call" >&2
      exit 3
    fi
    echo "$ROUND_TOKENS" >> "$LOG_FILE"
    TOTAL_SPENT=$((TOTAL_SPENT + ROUND_TOKENS))

    echo ""
    echo "--- round $ROUND critique ---"
    cat "$VERDICT_FILE"
    echo ""
    echo "(round tokens: $ROUND_TOKENS, cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
    echo ""

    {
      echo "## Round $ROUND"
      echo ""
      echo "- tokens: $ROUND_TOKENS (cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
      echo ""
      echo "critique:"
      echo '```'
      cat "$VERDICT_FILE"
      echo ""
      echo '```'
      echo ""
    } >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2

    # Budget is checked before the verdict: a round that blows the budget is
    # reported as a budget stop even if Codex's verdict in that same round
    # was PASS — "whichever comes first" means tokens can end the loop before
    # convergence is honored.
    if [ "$TOTAL_SPENT" -gt "$MAX_TOKENS" ]; then
      OUTCOME="token budget exceeded ($TOTAL_SPENT > $MAX_TOKENS)"
      # Codex's own proposal is only a valid candidate to offer when Codex is
      # allowed to fix itself (no key found, API_ARBITER=0). When a key was
      # found (API_ARBITER=1), Codex's fix was never authorized — only
      # Claude's would be, and Claude hasn't run yet this round, so there's
      # genuinely no candidate to offer.
      if [ "$API_ARBITER" -eq 0 ]; then
        NEW_PROPOSAL="$(extract_proposal "$VERDICT_FILE")"
        [ -n "$NEW_PROPOSAL" ] && { CANDIDATE="$NEW_PROPOSAL"; printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"; }
      else
        # A CANDIDATE from an earlier hypothetical-review round is stale here —
        # this round's fresh Codex critique found something (or ran out of
        # budget before we know), and Claude never got to weigh in on it.
        CANDIDATE=""
        rm -f "$CANDIDATE_FILE"
      fi
      break
    fi

    NEW_PROPOSAL="$(extract_proposal "$VERDICT_FILE")"
    PASSED=0
    last_line_is_pass "$VERDICT_FILE" && PASSED=1

    if [ "$PASSED" -eq 1 ]; then
      OUTCOME="converged"
      break
    fi

    if [ -z "$NEW_PROPOSAL" ] && [ "$API_ARBITER" -eq 0 ]; then
      OUTCOME="stalled — Codex flagged problems but proposed no fix to iterate on"
      break
    fi
    # When a key was found (API_ARBITER=1), Codex not proposing a fix isn't
    # stalling — Codex is evaluator-only in this mode, so its own fix was
    # never required. Claude constructs a correction from Codex's critique
    # (and the real content) whether or not Codex happened to include one.

    if [ "$API_ARBITER" -eq 1 ]; then
      # Codex is the evaluator only in this mode — it judges but never writes the
      # accepted fix, the same rule --evaluator claude already follows in reverse.
      # Codex's own proposed fix (NEW_PROPOSAL) is shown to Claude as context/a
      # hint, but is never used directly — Claude either writes its own corrected
      # version, or disputes the finding and Codex reconsiders. Symmetric with
      # the reversed direction: whichever model is NOT the evaluator is the one
      # that acts (fix or defend), the evaluator only ever judges.
      {
        echo "Codex reviewed an artifact against the brief and criteria below and found a problem,"
        echo "proposing its own fix. In this mode Codex's proposed fix is not used directly — you decide"
        echo "independently what happens next. Apply the same skepticism to Codex's claim that Codex is"
        echo "asked to apply to the artifact; don't take it on faith just because it sounds plausible."
        echo ""
        echo "Brief and criteria:"
        cat "$BRIEF"
        echo ""
        echo "The exact content Codex just reviewed this round (the real file on round 1, a hypothetical"
        echo "candidate revision on later rounds — either way, this is what Codex's critique below is"
        echo "actually about, not necessarily $ARTIFACT's current on-disk content):"
        echo '```'
        printf '%s\n' "$REVIEWED_CONTENT"
        echo '```'
        echo ""
        echo "Codex's critique, and Codex's OWN proposed fix (context only, not authoritative — you may"
        echo "agree with it, write a different fix, or reject the finding entirely):"
        echo '```'
        cat "$VERDICT_FILE"
        echo ""
        echo '```'
        echo ""
        echo "Check Codex's claim against the exact content shown above — don't just judge whether it sounds"
        echo "plausible, verify it against the real content."
        echo ""
        echo "If Codex's finding is legitimate: write your OWN corrected version of the full artifact that"
        echo "resolves it — it does not need to match Codex's proposed fix. Wrap it EXACTLY like this,"
        echo "nothing else inside:"
        echo "$BEGIN_MARK"
        echo "<full corrected content of the artifact>"
        echo "$END_MARK"
        echo "Then end your reply with exactly: ARBITER: AGREE"
        echo ""
        echo "If you dispute the finding: do NOT include a fix block. Say exactly what you dispute and why,"
        echo "citing specifics from the content/brief, then end your reply with exactly: ARBITER: DISPUTE"
        echo ""
        echo "Your reply's exact final non-blank line must be one of those two lines, nothing else."
      } > "$CLAUDE_PROMPT_FILE"

      if ! bash "$SCRIPT_DIR/claude_call.sh" "$CLAUDE_PROMPT_FILE" "$CLAUDE_OUT" "$CLAUDE_USAGE"; then
        echo "error: claude_call.sh (api arbiter) failed — see message above" >&2
        exit 3
      fi
      ARBITER_TOKENS="$(cat "$CLAUDE_USAGE" 2>/dev/null || echo 0)"
      echo "$ARBITER_TOKENS" >> "$LOG_FILE"
      TOTAL_SPENT=$((TOTAL_SPENT + ARBITER_TOKENS))

      echo ""
      echo "--- round $ROUND: API evaluator's response ---"
      cat "$CLAUDE_OUT"
      echo ""
      echo "(arbiter tokens: $ARBITER_TOKENS, cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
      echo ""

      {
        echo "### API evaluator (Claude)"
        echo ""
        echo "- tokens: $ARBITER_TOKENS (cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
        echo ""
        echo '```'
        cat "$CLAUDE_OUT"
        echo ""
        echo '```'
        echo ""
      } >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2

      if [ "$TOTAL_SPENT" -gt "$MAX_TOKENS" ]; then
        OUTCOME="token budget exceeded ($TOTAL_SPENT > $MAX_TOKENS)"
        # Claude's response, if any, hasn't been validated/extracted yet at this
        # point — don't guess at a candidate. Also clear whatever CANDIDATE was
        # carried in from a prior round: it was already reviewed and found
        # wanting this round, so offering it at Wrap-up would present something
        # neither Codex's current critique nor Claude approved.
        CANDIDATE=""
        rm -f "$CANDIDATE_FILE"
        break
      fi

      if last_line_is_arbiter_agree "$CLAUDE_OUT"; then
        CLAUDE_FIX="$(extract_proposal "$CLAUDE_OUT")"
        if [ -z "$CLAUDE_FIX" ]; then
          echo "error: API evaluator said ARBITER: AGREE but included no $BEGIN_MARK/$END_MARK fix block — treating as a failed call rather than guessing" >&2
          exit 3
        fi
        CANDIDATE="$CLAUDE_FIX"
        printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"
      elif last_line_is_arbiter_dispute "$CLAUDE_OUT"; then
        PENDING_OBJECTION="$(cat "$CLAUDE_OUT")"
        if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
          OUTCOME="round limit reached ($MAX_ROUNDS) — with an evaluator dispute still pending, unresolved"
          # Whatever CANDIDATE carried in from a prior round was disputed
          # unresolved this round — don't offer it as if it were approved.
          CANDIDATE=""
          rm -f "$CANDIDATE_FILE"
          break
        fi
        ROUND=$((ROUND + 1))
        continue
      else
        echo "error: API evaluator's reply didn't end in exactly 'ARBITER: AGREE' or 'ARBITER: DISPUTE' — treating as a failed call rather than guessing" >&2
        exit 3
      fi
    else
      # No API key / no arbiter: Codex is the only model reachable in this
      # unattended script, so it necessarily judges AND fixes itself — there is
      # no other model available to hand the fix to without a paid API call.
      CANDIDATE="$NEW_PROPOSAL"
      printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"
    fi

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
      OUTCOME="round limit reached ($MAX_ROUNDS)"
      break
    fi
    ROUND=$((ROUND + 1))
  done

else
  # ------------------------------------------------- reversed: codex builds, claude evaluates ----
  CLAUDE_FEEDBACK=""
  while true; do
    # 1. Codex builds or revises (still read-only — producing text, not writing files)
    rm -f "$VERDICT_FILE" "$RAW_FILE"
    if [ -z "$THREAD_ID" ]; then
      echo "== round $ROUND: Codex builds (new session) =="
      PROMPT_TEXT="$(cat "$BRIEF")

Produce the artifact content per the brief above (or, if it already exists, the additions/fix it
calls for). Output ONLY the content, wrapped exactly like this, nothing outside the markers:
$BEGIN_MARK
<content>
$END_MARK"
      CODEX_ARGS=(-s read-only --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      NEW_THREAD="$(extract_thread_id "$RAW_FILE")"
      if [ "$CODEX_STATUS" -ne 0 ] || [ -z "$NEW_THREAD" ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex build call failed (exit $CODEX_STATUS) — check auth (codex login status) and model config" >&2
        exit 3
      fi
      THREAD_ID="$NEW_THREAD"
    else
      echo "== round $ROUND: Codex revises (resuming $THREAD_ID) =="
      PROMPT_TEXT="The evaluator raised this objection: $CLAUDE_FEEDBACK

Revise your proposal to address it, or explain why you're keeping it as-is if the objection
doesn't hold up. Output the (possibly revised) content wrapped exactly like this:
$BEGIN_MARK
<content>
$END_MARK"
      CODEX_ARGS=(resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json -o "$VERDICT_FILE")
      run_codex
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    fi

    if ! CODEX_TOKENS="$(sum_codex_usage "$RAW_FILE")"; then
      echo "error: couldn't determine round token usage from codex output — treating as a failed call" >&2
      exit 3
    fi

    CANDIDATE="$(extract_proposal "$VERDICT_FILE")"
    if [ -z "$CANDIDATE" ]; then
      echo "$CODEX_TOKENS" >> "$LOG_FILE"
      TOTAL_SPENT=$((TOTAL_SPENT + CODEX_TOKENS))
      OUTCOME="stalled — Codex produced no content to evaluate"
      {
        echo "## Round $ROUND (stalled)"
        echo ""
        echo "- tokens: $CODEX_TOKENS (cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
        echo ""
        echo "Codex returned no valid $BEGIN_MARK/$END_MARK block. Raw output:"
        echo '```'
        cat "$VERDICT_FILE"
        echo ""
        echo '```'
        echo ""
      } >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2
      break
    fi
    printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"
    echo ""
    echo "--- round $ROUND: Codex produced ---"
    cat "$CANDIDATE_FILE"
    echo ""

    # 2. Claude evaluates, via a direct API call — no tool access, so anything it
    # needs to check a claim against has to be handed to it directly in the prompt.
    {
      echo "You are an adversarial reviewer. Be skeptical and specific — your job is to find what's"
      echo "wrong, not to be agreeable."
      echo ""
      echo "Review brief and criteria:"
      cat "$BRIEF"
      echo ""
      if [ -s "$ARTIFACT" ]; then
        echo "Real content of $ARTIFACT as it stood before this round (ground truth — verify Codex's"
        echo "output against this, don't just take Codex's framing of it on faith):"
        echo '```'
        cat "$ARTIFACT"
        echo ""
        echo '```'
        echo ""
      fi
      echo "Codex produced the following for this artifact:"
      echo "$BEGIN_MARK"
      cat "$CANDIDATE_FILE"
      echo ""
      echo "$END_MARK"
      echo ""
      echo "Check it against the criteria above — verify claims against the real content shown above"
      echo "where there is any, don't just eyeball Codex's own framing, watch for brittle or misleading"
      echo "elements. End your reply with exactly one line: RESULT: PASS if it's sound, or RESULT: FAIL"
      echo "if there's a material problem. If FAIL, give the specific objection in one or two sentences."
    } > "$CLAUDE_PROMPT_FILE"

    if ! bash "$SCRIPT_DIR/claude_call.sh" "$CLAUDE_PROMPT_FILE" "$CLAUDE_OUT" "$CLAUDE_USAGE"; then
      echo "error: claude_call.sh failed — see message above" >&2
      exit 3
    fi
    CLAUDE_TOKENS="$(cat "$CLAUDE_USAGE" 2>/dev/null || echo 0)"

    ROUND_TOKENS=$((CODEX_TOKENS + CLAUDE_TOKENS))
    echo "$ROUND_TOKENS" >> "$LOG_FILE"
    TOTAL_SPENT=$((TOTAL_SPENT + ROUND_TOKENS))

    echo "--- round $ROUND: Claude's evaluation ---"
    cat "$CLAUDE_OUT"
    echo ""
    echo "(round tokens: $ROUND_TOKENS [codex: $CODEX_TOKENS, claude: $CLAUDE_TOKENS], cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
    echo ""

    {
      echo "## Round $ROUND"
      echo ""
      echo "- tokens: $ROUND_TOKENS [codex: $CODEX_TOKENS, claude: $CLAUDE_TOKENS] (cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
      echo ""
      echo "Codex produced:"
      echo '```'
      cat "$CANDIDATE_FILE"
      echo ""
      echo '```'
      echo ""
      echo "Claude's evaluation:"
      echo '```'
      cat "$CLAUDE_OUT"
      echo '```'
      echo ""
    } >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2

    # Budget checked before the verdict — see the forward-loop comment above
    # for why "whichever comes first" means tokens can end the loop even in
    # the same round a PASS would otherwise have been read as convergence.
    if [ "$TOTAL_SPENT" -gt "$MAX_TOKENS" ]; then
      OUTCOME="token budget exceeded ($TOTAL_SPENT > $MAX_TOKENS)"
      break
    fi

    PASSED=0
    last_line_is_pass "$CLAUDE_OUT" && PASSED=1
    if [ "$PASSED" -eq 1 ]; then
      OUTCOME="converged"
      break
    fi

    CLAUDE_FEEDBACK="$(cat "$CLAUDE_OUT")"

    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
      OUTCOME="round limit reached ($MAX_ROUNDS)"
      break
    fi
    ROUND=$((ROUND + 1))
  done
fi

# -------------------------------------------------------------- result ----
AUDIT_FINALIZED=1
{
  echo "## Outcome"
  echo ""
  echo "- outcome: $OUTCOME"
  echo "- rounds: $ROUND"
  echo "- tokens: $TOTAL_SPENT / $MAX_TOKENS"
  echo "- thread: $THREAD_ID"
} >> "$AUDIT_LOG_FILE" || echo "warning: failed to append to audit log at $AUDIT_LOG_FILE — this round's record may be incomplete" >&2

echo "======================================"
echo "outcome: $OUTCOME"
echo "rounds:  $ROUND"
echo "tokens:  $TOTAL_SPENT / $MAX_TOKENS"
echo "thread:  $THREAD_ID"
echo "log:     $AUDIT_LOG_FILE"
echo "======================================"

if [ -z "$CANDIDATE" ]; then
  if [ "$OUTCOME" = "converged" ]; then
    echo ""
    echo "No changes were ever needed — Codex approved the artifact as-is."
    exit 0
  fi
  echo ""
  echo "Stopped without approval ('$OUTCOME') and no candidate fix exists to review."
  exit 1
fi

echo ""
echo "A candidate fix is ready. Here is exactly what would be written to $ARTIFACT:"
if [ "$OUTCOME" != "converged" ]; then
  echo "NOTE: this candidate was NOT approved by Codex — the loop stopped on '$OUTCOME' before it converged."
fi
echo ""
if command -v diff >/dev/null 2>&1; then
  echo "--- diff against the current file (- current, + candidate) ---"
  diff -u "$ARTIFACT" "$CANDIDATE_FILE" || true
else
  echo "--- full candidate content ---"
  cat "$CANDIDATE_FILE"
  echo ""
fi
echo "---"
echo ""
printf "Apply the above to %s now? [y/N]: " "$ARTIFACT"
read -r APPLY_ANSWER
case "$APPLY_ANSWER" in
  [yY]|[yY][eE][sS])
    cp "$ARTIFACT" "${ARTIFACT}.bak-$(date +%s)"
    cp "$CANDIDATE_FILE" "$ARTIFACT"
    echo "written to $ARTIFACT (backup saved alongside it)."
    exit 0
    ;;
  *)
    echo "not applied. Candidate left at: $CANDIDATE_FILE"
    exit 1
    ;;
esac
