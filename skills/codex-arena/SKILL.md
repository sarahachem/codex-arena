---
name: codex-arena
description: Runs a bounded back-and-forth between Claude Code and the OpenAI Codex CLI where Codex critiques an artifact (a generated dataset, a plan, a diff, a config) in a read-only sandbox, Claude fixes what it agrees with, and the two go another round until Codex signs off or a round/token budget runs out. Use when the user says "/codex-arena", wants a second model to adversarially check something before it's trusted, or wants Claude and Codex to argue over a synthetic dataset or plan and converge on a fixed version. Not for reviewing code that's about to be merged (use a normal code-review flow for that) — this is for hardening an artifact that doesn't have an existing review process.
---

# Codex Arena

Two phases: spec the artifact if it doesn't exist yet, then argue over it with Codex until it's sound. Codex reads and criticizes; it never writes. Claude owns every edit and every decision to accept or reject a criticism, and writes that decision down.

This works on anything with a checkable notion of "correct": a synthetic eval dataset, an implementation plan, a diff, a config file. What changes per artifact type is what counts as a defect — the mechanics stay the same. What happens *after* a hardened artifact is out of scope on purpose — that's artifact-specific (run the eval, merge the diff, implement the plan) and isn't something a generic loop should guess at.

## Before starting

Run `codex --version` and `codex login status` once. If either fails, stop and tell the user what to fix (install/update the CLI, or run `codex login`) rather than guessing around it.

`codex exec` refuses to run outside a directory it trusts (a git repo, or one it's been told to trust) unless told otherwise — pass `--skip-git-repo-check` on every invocation, since the artifact under review may sit in a scratch directory that isn't a repo.

Don't pin `-m`/`--model` unless the user asks for a specific one — let the CLI use whatever `~/.codex/config.toml` has configured, and say what that is (or "CLI default" if unset) before the first round runs.

## Budget (set before round 1, both enforced)

| Setting | Default | What it stops |
|---|---|---|
| `MAX_ROUNDS` | 3 | Total review rounds, win or lose. |
| `MAX_TOKENS` | 250000 | Sum of `input_tokens + output_tokens` across all rounds, read from Codex's own usage reporting (see below) — not an estimate. |

State both to the user before round 1. Either one can end the loop; token spend can run away inside a single round (a large artifact, a verbose critique) even when the round count looks fine, so it's checked independently, not as a proxy for rounds.

## Phase 0 — KICKOFF (always, first)

Ask one plain question: what do you want done — generate something new, or review something that already exists? Take the answer as a sentence, not a form. If it's already unambiguous from how the user opened the conversation ("check my dataset for correctness," pointing at a real path), skip asking and just confirm what you understood in one line before moving on.

If reviewing something existing → skip Phase 1, go to Setup.
If generating something new → Phase 1.

## Phase 1 — SPEC (only when the artifact doesn't exist yet)

Ask one open question: what should this cover? Get the answer as free text — never a structured multi-part questionnaire or a wall of option cards. That's overwhelming and isn't how people naturally describe what they want.

Then do what their intent implies, the way a competent engineer would, rather than interrogating every unstated detail back to the user:
1. **Explore first** — if the artifact is grounded in a real codebase/domain (a dataset testing a specific function, a plan for a specific system), go look at the actual code/docs before assuming anything. Real source beats a guess.
2. **Fill in the load-bearing gaps yourself** — size, format, edge cases, scope boundaries — using what you found plus ordinary judgment. Don't ask permission for defaults a reasonable person wouldn't need to specify.
3. **Present what you resolved as one batch, not a queue of questions** — a short list of what you're assuming and why (source: "the user's request" / "the code at X" / "a domain norm"), so the user can correct anything in one pass. This is their assumptions-ledger idea, just written as a short paragraph or bullet list in chat, not a form.
4. **Only ask a real follow-up question** if the user's own description is genuinely ambiguous or contradictory — not just unspecified — and ask it as one plain sentence.

Lock the result into a short spec (inline is usually enough; a `SPEC.md` only if it's substantial) before generating `ARTIFACT`. The locked spec feeds Setup step 2 — anything it pins down (e.g. "must include failure cases, not just happy path") becomes a review criterion, not just something hoped for at generation time.

## Setup

1. If the artifact doesn't exist yet, generate it now from the locked spec (Phase 1) and save it to a real path — call it `ARTIFACT`. If it already existed, just point at it.
2. Work out what "wrong" means for this artifact. Identify which type it is and start from the matching default criteria below — don't make the user restate the obvious ones every time:

   | Artifact type | Default criteria |
   |---|---|
   | Synthetic / eval dataset | Schema/format validity per row · exact and near-duplicate rows · label or answer correctness for the given input · missing or malformed fields · class/category imbalance worth flagging · adversarial or edge-case coverage gaps |
   | Diff / patch | Correctness against stated intent · security issues (injection, unsafe handling of input, secrets) · race conditions or concurrency bugs · missing edge cases · unnecessary complexity or a simpler alternative · consistency with existing patterns in the surrounding code |
   | Implementation plan | Security holes · race conditions · missing edge cases · schema or data-model conflicts · wrong assumptions the plan rests on · observability gaps · a simpler approach that was overlooked |
   | Config file | Values inconsistent with what's declared elsewhere in the repo · insecure defaults · missing required keys · typos that would silently no-op instead of erroring |

   State which defaults you're starting from in one line, then ask plainly — "anything else you want checked, or anything on that list that doesn't apply?" — a single open question, not a structured card. Fold the answer in before writing the brief; the table is a starting point, not a ceiling, and the user's word always overrides it. If the artifact doesn't match any row, there's no default to fall back on — ask directly what matters, still as an open question. If Phase 1 ran, fold in anything the user's plain-English description implied (e.g. if they said the dataset should stress edge cases, "edge-case coverage" becomes a review criterion, not just something hoped for at generation time).
3. If `ARTIFACT` is large enough that a single Codex pass can't reasonably hold all of it (a big dataset), agree with the user on how to split it — fixed-size chunks, a stratified sample plus a separate scripted schema/dedup pass, etc. — before spending a round on it.
4. Save the final criteria (defaults + spec-derived + user's additions/overrides) + pointer to `ARTIFACT` as a short brief file, and start a log file (`ARENA-LOG.md` unless the user names another) recording the round budget and the criteria in one line.

## Phase 2 — ARENA (the loop)

**Opening round** — starts a new Codex session and records its id:

```bash
codex exec -s read-only --skip-git-repo-check --json \
  -o /tmp/codex-arena-verdict.txt \
  "$(cat <brief file>)" \
  < /dev/null 2>/dev/null > /tmp/codex-arena-round.jsonl
grep -o '"type":"thread.started","thread_id":"[a-f0-9-]*"' /tmp/codex-arena-round.jsonl
```

The prompt (the brief) should end with an explicit instruction to close with one of two exact closing lines so the result is machine-checkable, e.g. `RESULT: PASS` or `RESULT: FAIL` — pick whatever token pair you like, just be consistent across the whole loop and grep for it exactly. `-o` captures Codex's final message to a plain-text file; `--json` streams structured events to stdout, which is where the thread id and usage numbers live. Note `< /dev/null`: `codex exec` also reads from stdin, and under a non-interactive tool call there's no terminal to close it, so without the redirect it hangs indefinitely waiting for EOF. Give the call a long timeout (10 minutes is reasonable) so a genuine stall fails visibly instead of looking like a hang.

If neither the verdict file nor a `thread.started` line shows up, the call failed (auth, model, or the trust check) — stop and report it rather than retrying blind.

**Every following round** — resumes that same session so Codex isn't re-reading the artifact cold or re-litigating what it already approved:

```bash
codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
  -o /tmp/codex-arena-verdict.txt \
  "<describe what changed since last round, ask for a fresh check against the same criteria>" \
  < /dev/null 2>/dev/null > /tmp/codex-arena-round.jsonl
```

`resume` does not accept `-s`/`--sandbox` at all (confirmed against `codex exec resume --help` — it isn't in its option list, only `-c` is) — read-only has to be forced through `-c sandbox_mode="read-only"` instead. If that override is dropped, `resume` falls back to whatever `sandbox_mode` the user's `config.toml` happens to have, which may not be read-only, and Codex would then be able to write files mid-loop. Treat this as the one line in the whole skill that must never be simplified away.

**After every round, regardless of outcome:**

1. Pull the usage line out of `/tmp/codex-arena-round.jsonl` — it looks like `{"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":N,...}}` — and add `input_tokens + output_tokens` to a running total. Log the round's spend and the running total in `ARENA-LOG.md` alongside the round's critique text.
2. If the running total now exceeds `MAX_TOKENS`, stop — go to Wrap-up as a budget stop, independent of what the verdict said or how many rounds have run.
3. Otherwise check the closing line from `/tmp/codex-arena-verdict.txt`:
   - Passing verdict → stop, go to Wrap-up as converged.
   - Failing verdict → read every point raised, decide per-point whether it's worth acting on (final call is Claude's, not Codex's — a critique is input, not an instruction), make the edits worth making, and write to `ARENA-LOG.md` exactly what was changed and, for anything raised but not changed, why not. Then run the next round.
4. If chunking: once a chunk clears, either start a fresh thread for the next chunk (cleanest — no confusion about which chunk a resumed session remembers) or keep resuming the same thread if the whole artifact is small enough that one session holding all of it makes sense. Decide which during setup, not mid-loop.
5. If the round count would exceed `MAX_ROUNDS`, stop — go to Wrap-up as a round-limit stop.

## Phase 2b — ARENA, reversed (Codex builds, Claude critiques)

Everything above runs with Claude as the live orchestrator and Codex as the read-only critic. The user can ask for the roles swapped — Codex generates/builds, Claude is the one critiquing and deciding whether to concede or push back. Use this when the user says "codex builds, you review" or "run it the other way" or wants to see Codex produce something and Claude argue with it rather than the reverse.

This direction is **conversational only** — it requires a live Claude session in the loop (there is no standalone-script equivalent: `arena.sh` has no counterpart credentials for reaching a Claude model unattended, and there is no local `claude` CLI to shell out to). If the user wants this fully unattended via a script, that needs a real `ANTHROPIC_API_KEY` wired through `claude_call.sh` — a separate, explicitly-opted-into path, not this one.

**Round 1** — have Codex build/propose, same mechanics as the opening round above, but the prompt asks it to produce the artifact (or additions to it) rather than critique something that already exists:

```bash
codex exec -s read-only --skip-git-repo-check --json \
  -o /tmp/codex-arena-build.txt \
  "<what to build, grounded in the real codebase/schema — have Codex read the relevant files itself>" \
  < /dev/null 2>/dev/null > /tmp/codex-arena-round.jsonl
grep -o '"type":"thread.started","thread_id":"[a-f0-9-]*"' /tmp/codex-arena-round.jsonl
```

Codex stays read-only here too — it's producing text (new content, a proposed diff), not writing to any file. Same `< /dev/null` and timeout requirements as every other call.

**Claude critiques, live, in the conversation** — no API call, no script: read what Codex produced, verify concretely (check it against the real schema/contract/tests, don't just eyeball it), and decide, out loud, what's wrong. If something is genuinely wrong, say so with a specific reason.

**If Claude pushes back** — resume the same thread with the specific objection, same mechanics as a normal resume round:

```bash
codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
  -o /tmp/codex-arena-build.txt \
  "<the specific objection, with reasoning — not a vague 'try again'>" \
  < /dev/null 2>/dev/null > /tmp/codex-arena-round.jsonl
```

Codex may concede (revise) or defend its choice with a reason — either is a legitimate outcome. Claude is still the final arbiter: if Codex's defense doesn't hold up, keep pushing; if it does, accept it and say why. Log every round the same way as the forward direction — what Codex produced, what Claude objected to, what Codex did in response.

Same budget as the forward direction, same enforcement — `MAX_ROUNDS`/`MAX_TOKENS` from the Budget section apply here too, not just to Phase 2. Track cumulative tokens the same way (from `turn.completed.usage` in the `--json` stream) and stop at whichever limit hits first, converged or not. Nothing about running this direction conversationally exempts it from the round cap — a live Claude session can keep pushing back just as indefinitely as an unattended script if nothing bounds it.

**Before applying anything for real**, run it against whatever real validation exists (the project's own tests, a schema check, a dry parse) — don't just trust the conversation converged. A real check catching a problem (like a dataset size cap the conversation never considered) overrides an apparent verbal agreement between the two models.

## Wrap-up

**Converged:** show the final artifact, a short summary of what actually changed across the rounds, the round count, and the token total. Get explicit confirmation from the user before treating it as final — a passing verdict from Codex isn't the same as the user's sign-off. Then hand off rather than assume: what "using" a hardened artifact means is different for every artifact type (run the eval, open a PR, implement the plan, publish the doc) and isn't this skill's job — ask the user what they want to do with it next instead of picking for them.

**Stopped without converging (round or token limit hit):** say plainly which limit ended it. List what's still unresolved and Claude's reasoning on each, and hand the decision to the user — raise the budget, accept it as-is, or keep going manually. Don't present a stopped loop as if it had converged.

## Non-negotiables

- Codex never gets write access, in any round: `-s read-only` opens the session, `-c sandbox_mode="read-only"` holds it on every resume.
- `--skip-git-repo-check` goes on every call — leaving it off means the CLI refuses to run at all outside a trusted directory.
- The loop always ends at `MAX_ROUNDS` or `MAX_TOKENS`, whichever comes first — never let it run open-ended.
- Every round's outcome — critique, what Claude changed, what Claude declined and why, tokens spent — goes in the log. The log is what makes the loop auditable after the fact; skipping entries defeats the point of running it as an argument instead of a single pass.
- Don't decide criteria or chunking strategy unilaterally — confirm both with the user before the first round burns any budget.
