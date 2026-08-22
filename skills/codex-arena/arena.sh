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
#   --evaluator codex (default): Codex critiques itself, proposes fixes as text.
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
MAX_ROUNDS=5
STATE_DIR="${CODEX_ARENA_STATE_DIR:-}"
INIT_MODE=0
INIT_OUT=""
NO_RUN=0
EVALUATOR="codex"

BEGIN_MARK="===BEGIN_PROPOSED_ARTIFACT==="
END_MARK="===END_PROPOSED_ARTIFACT==="

while [ $# -gt 0 ]; do
  case "$1" in
    --init) INIT_MODE=1; shift ;;
    --no-run) NO_RUN=1; shift ;;
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
    echo "Type anything to add, drop, or override — or just press enter on an empty"
    echo "first line to use the defaults above as-is. Finish with an empty line."
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
fi

echo "evaluator: $EVALUATOR $( [ "$EVALUATOR" = "claude" ] && echo "(Codex builds, Claude evaluates via direct API call)" || echo "(Codex builds and evaluates itself, read-only every round)" )"

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

# A pre-existing STATE_DIR (via CODEX_ARENA_STATE_DIR) is now verified to be a
# real, owned directory, but files already inside it could still be symlinks
# or pre-placed owned/hardlinked files planted before this run. Refuse rather
# than write/append through any of them — resuming a THREAD_ID intentionally
# reuses LOG_FILE across invocations, so this only rejects things that are NOT
# a plain regular file owned by the current user (a legitimate prior run's
# output passes; a symlink, device file, or someone else's file does not).
for f in "$VERDICT_FILE" "$RAW_FILE" "$LOG_FILE" "$CANDIDATE_FILE" "$CLAUDE_PROMPT_FILE" "$CLAUDE_OUT" "$CLAUDE_USAGE"; do
  if [ -L "$f" ]; then
    echo "error: $f already exists as a symlink (possibly dangling), refusing to use this state dir" >&2
    exit 2
  fi
  if [ -e "$f" ] && { [ ! -f "$f" ] || [ ! -O "$f" ]; }; then
    echo "error: $f already exists and isn't a plain file you own, refusing to use this state dir" >&2
    exit 2
  fi
done

# reset per-invocation token log unless resuming a prior thread
if [ -z "$THREAD_ID" ]; then
  : > "$LOG_FILE"
fi
rm -f "$CANDIDATE_FILE"

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

# ---------------------------------------------------------- round loop ----
ROUND=1
CANDIDATE=""
OUTCOME=""

if [ "$EVALUATOR" = "codex" ]; then
  while true; do
    rm -f "$VERDICT_FILE" "$RAW_FILE"
    if [ -z "$THREAD_ID" ]; then
      echo "== round $ROUND (new session) =="
      codex exec -s read-only --skip-git-repo-check --json \
        -o "$VERDICT_FILE" \
        "$(cat "$BRIEF")" \
        < /dev/null 2>/dev/null > "$RAW_FILE"
      CODEX_STATUS=$?
      NEW_THREAD="$(grep -o '"type":"thread.started","thread_id":"[a-f0-9-]*"' "$RAW_FILE" | grep -o '[a-f0-9-]\{36\}')"
      if [ "$CODEX_STATUS" -ne 0 ] || [ -z "$NEW_THREAD" ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex call failed (exit $CODEX_STATUS) — check auth (codex login status) and model config" >&2
        exit 3
      fi
      THREAD_ID="$NEW_THREAD"
    elif [ -n "$CANDIDATE" ]; then
      echo "== round $ROUND (resuming $THREAD_ID — reviewing proposed fix as a hypothetical) =="
      RESUME_PROMPT="Here is a candidate revision incorporating the fix you proposed. This has NOT been
written to the real file — it is purely hypothetical, for you to re-review as if it replaced
$ARTIFACT. Check it against the same brief and criteria as before.

$BEGIN_MARK
$CANDIDATE
$END_MARK

If this fully resolves everything, respond with the same PASS verdict format as before and
omit the proposal block. If problems remain, describe them and propose an updated corrected
version using the same $BEGIN_MARK / $END_MARK markers."
      codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
        -o "$VERDICT_FILE" \
        "$RESUME_PROMPT" \
        < /dev/null 2>/dev/null > "$RAW_FILE"
      CODEX_STATUS=$?
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    else
      echo "== round $ROUND (resuming $THREAD_ID) =="
      codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
        -o "$VERDICT_FILE" \
        "Re-check $ARTIFACT against the same brief and criteria. End with the same exact verdict format as before." \
        < /dev/null 2>/dev/null > "$RAW_FILE"
      CODEX_STATUS=$?
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    fi

    ROUND_TOKENS="$(grep -o '"type":"turn.completed","usage":{[^}]*}' "$RAW_FILE" \
      | grep -o '"input_tokens":[0-9]*\|"output_tokens":[0-9]*' \
      | grep -o '[0-9]*' | awk '{sum+=$1} END{print sum+0}')"
    echo "$ROUND_TOKENS" >> "$LOG_FILE"
    TOTAL_SPENT=$((TOTAL_SPENT + ROUND_TOKENS))

    echo ""
    echo "--- round $ROUND critique ---"
    cat "$VERDICT_FILE"
    echo ""
    echo "(round tokens: $ROUND_TOKENS, cumulative: $TOTAL_SPENT / $MAX_TOKENS)"
    echo ""

    NEW_PROPOSAL="$(extract_proposal "$VERDICT_FILE")"
    PASSED=0
    last_line_is_pass "$VERDICT_FILE" && PASSED=1

    if [ "$PASSED" -eq 1 ]; then
      OUTCOME="converged"
      break
    fi

    if [ -z "$NEW_PROPOSAL" ]; then
      OUTCOME="stalled — Codex flagged problems but proposed no fix to iterate on"
      break
    fi
    CANDIDATE="$NEW_PROPOSAL"
    printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"

    if [ "$TOTAL_SPENT" -gt "$MAX_TOKENS" ]; then
      OUTCOME="token budget exceeded ($TOTAL_SPENT > $MAX_TOKENS)"
      break
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
      BUILD_PROMPT="$(cat "$BRIEF")

Produce the artifact content per the brief above (or, if it already exists, the additions/fix it
calls for). Output ONLY the content, wrapped exactly like this, nothing outside the markers:
$BEGIN_MARK
<content>
$END_MARK"
      codex exec -s read-only --skip-git-repo-check --json \
        -o "$VERDICT_FILE" \
        "$BUILD_PROMPT" \
        < /dev/null 2>/dev/null > "$RAW_FILE"
      CODEX_STATUS=$?
      NEW_THREAD="$(grep -o '"type":"thread.started","thread_id":"[a-f0-9-]*"' "$RAW_FILE" | grep -o '[a-f0-9-]\{36\}')"
      if [ "$CODEX_STATUS" -ne 0 ] || [ -z "$NEW_THREAD" ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex build call failed (exit $CODEX_STATUS) — check auth (codex login status) and model config" >&2
        exit 3
      fi
      THREAD_ID="$NEW_THREAD"
    else
      echo "== round $ROUND: Codex revises (resuming $THREAD_ID) =="
      codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
        -o "$VERDICT_FILE" \
        "The evaluator raised this objection: $CLAUDE_FEEDBACK

Revise your proposal to address it, or explain why you're keeping it as-is if the objection
doesn't hold up. Output the (possibly revised) content wrapped exactly like this:
$BEGIN_MARK
<content>
$END_MARK" \
        < /dev/null 2>/dev/null > "$RAW_FILE"
      CODEX_STATUS=$?
      if [ "$CODEX_STATUS" -ne 0 ] || [ ! -s "$VERDICT_FILE" ]; then
        echo "error: codex resume failed for thread $THREAD_ID (exit $CODEX_STATUS)" >&2
        exit 3
      fi
    fi

    CODEX_TOKENS="$(grep -o '"type":"turn.completed","usage":{[^}]*}' "$RAW_FILE" \
      | grep -o '"input_tokens":[0-9]*\|"output_tokens":[0-9]*' \
      | grep -o '[0-9]*' | awk '{sum+=$1} END{print sum+0}')"

    CANDIDATE="$(extract_proposal "$VERDICT_FILE")"
    if [ -z "$CANDIDATE" ]; then
      echo "$CODEX_TOKENS" >> "$LOG_FILE"
      TOTAL_SPENT=$((TOTAL_SPENT + CODEX_TOKENS))
      OUTCOME="stalled — Codex produced no content to evaluate"
      break
    fi
    printf '%s' "$CANDIDATE" > "$CANDIDATE_FILE"
    echo ""
    echo "--- round $ROUND: Codex produced ---"
    cat "$CANDIDATE_FILE"
    echo ""

    # 2. Claude evaluates, via a direct API call — read-only by nature, no tool access
    {
      echo "You are an adversarial reviewer. Be skeptical and specific — your job is to find what's"
      echo "wrong, not to be agreeable."
      echo ""
      echo "Review brief and criteria:"
      cat "$BRIEF"
      echo ""
      echo "Codex produced the following for this artifact:"
      echo "$BEGIN_MARK"
      cat "$CANDIDATE_FILE"
      echo "$END_MARK"
      echo ""
      echo "Check it against the criteria above — verify claims against real logic where you can,"
      echo "don't just eyeball it, watch for brittle or misleading elements. End your reply with"
      echo "exactly one line: RESULT: PASS if it's sound, or RESULT: FAIL if there's a material"
      echo "problem. If FAIL, give the specific objection in one or two sentences."
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

    PASSED=0
    last_line_is_pass "$CLAUDE_OUT" && PASSED=1
    if [ "$PASSED" -eq 1 ]; then
      OUTCOME="converged"
      break
    fi

    CLAUDE_FEEDBACK="$(cat "$CLAUDE_OUT")"

    if [ "$TOTAL_SPENT" -gt "$MAX_TOKENS" ]; then
      OUTCOME="token budget exceeded ($TOTAL_SPENT > $MAX_TOKENS)"
      break
    fi
    if [ "$ROUND" -ge "$MAX_ROUNDS" ]; then
      OUTCOME="round limit reached ($MAX_ROUNDS)"
      break
    fi
    ROUND=$((ROUND + 1))
  done
fi

# -------------------------------------------------------------- result ----
echo "======================================"
echo "outcome: $OUTCOME"
echo "rounds:  $ROUND"
echo "tokens:  $TOTAL_SPENT / $MAX_TOKENS"
echo "thread:  $THREAD_ID"
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
