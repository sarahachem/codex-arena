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

**Ask who evaluates — this is the user's decision, not a default to infer.** Don't assume Phase 2's Claude-orchestrates/Codex-evaluates direction just because it's more common, and don't require the user to phrase a specific trigger word to get the other direction. Ask plainly: "who should evaluate — Codex, or Claude?" Take the answer, then state it back explicitly before round 1 runs, in the same breath as the model/budget confirmation from "Before starting": e.g. "Codex is the evaluator, Claude orchestrates" (→ Phase 2) or "Claude is the evaluator, Codex builds" (→ Phase 2b).

## Phase 1 — SPEC (only when the artifact doesn't exist yet)

Ask one open question to start: what should this cover? Get the answer as free text — never a structured multi-part questionnaire or a wall of option cards. That's overwhelming and isn't how people naturally describe what they want.

Then grill, don't guess. Grilling means: find every real unsettled decision that would change what gets built, and put the whole batch to the user in one round of plain sentences — not trickled out one at a time, and not silently resolved on the user's behalf just because a plausible default exists. This is the difference between "ask one open question" and actually working out what's still unknown after that answer:

1. **Explore first** — if the artifact is grounded in a real codebase/domain (a dataset testing a specific function, a plan for a specific system), go look at the actual code/docs before assuming anything. Real source beats a guess, and answers some questions before they need asking.
2. **Find the frontier of what's still unsettled** — after exploring, list every decision that (a) actually changes the shape of the artifact and (b) isn't already pinned down by the user's description or the real source you found. Size, format, edge-case coverage, and scope boundaries only belong on this list if a wrong guess would mean redoing real work — routine defaults a reasonable person wouldn't need to specify don't belong here at all.
3. **Separate the gap into two piles**: questions genuinely worth asking, and questions that are *ungrillable* — ones no amount of asking will resolve because the honest answer is "I'll know it when I see it" (tone, exact phrasing, how something should feel, a close call between two similar structures). For an ungrillable item, don't ask — say so, make a concrete choice, and put it in front of the user as something to react to once it exists, not something to specify in the abstract.
4. **Put the grillable questions to the user in one round**, as plain sentences the way a colleague would ask, covering the whole frontier from step 2 at once rather than a queue of follow-ups. If answers to some questions would only matter depending on the answer to others, ask the prerequisite first and hold the dependent ones rather than asking something conditional that might not apply.
5. **State the ungrillable calls you made** alongside the questions, each with why it can't be resolved by asking and what you picked instead — so the user can react to the choice rather than being asked to specify it blind.
6. **Only re-open a second round** if an answer reveals a new unsettled decision that wasn't visible before (a genuinely dependent question) — not to revisit something already settled. Passive one-word confirmations back from the user are a signal the round didn't actually engage them; if that happens, it's worth checking whether the questions were substantive or just surface-level.

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

   State which defaults you're starting from in one line, then grill for the rest — this is the same batched, one-round approach as Phase 1, not a single generic "anything else?" State the defaults, then ask directly about anything genuinely unsettled for *this* artifact (a domain-specific risk the generic table can't know about, a criterion that clearly doesn't apply here, a tradeoff between two reasonable review depths) — as plain sentences, in one round, not a structured card and not skipped because the table looks sufficient. Fold the answer in before writing the brief; the table is a starting point, not a ceiling, and the user's word always overrides it. If the artifact doesn't match any row, there's no default to fall back on — ask directly what matters, still as an open, batched question rather than assuming criteria yourself. If Phase 1 ran, fold in anything the user's plain-English description implied (e.g. if they said the dataset should stress edge cases, "edge-case coverage" becomes a review criterion, not just something hoped for at generation time). Skipping this step because the request "sounded complete" is exactly the failure mode this exists to prevent — a criteria table that looks sufficient is not the same as one the user actually confirmed.
3. If `ARTIFACT` is large enough that a single Codex pass can't reasonably hold all of it (a big dataset), agree with the user on how to split it — fixed-size chunks, a stratified sample plus a separate scripted schema/dedup pass, etc. — before spending a round on it.
4. Save the brief file. It must open with the reviewer's posture, not just criteria — a brief that's only a checklist reads as a request for approval, not a real review:

   > You are an adversarial reviewer. Be skeptical and specific — your job is to find what's wrong, not to be agreeable.

   Then the final criteria (defaults + spec-derived + user's additions/overrides) + pointer to `ARTIFACT`. Start a log file (`ARENA-LOG.md` unless the user names another) recording the round budget and the criteria in one line.

## Phase 2 — ARENA (the loop)

**Who proposes the fix depends on what `ARTIFACT` is — this is not optional, get it right before round 1:**

- **Live source code, with Claude orchestrating conversationally** (Claude has Edit/Write tools and full codebase context right now): **Codex only critiques. Never ask it to propose a fix, a diff, or a patch.** Its job ends at identifying what's wrong and why. When something is confirmed real, Claude implements the fix directly in the actual files using its own tools — grounded in the real surrounding code, able to run the project's own tests — not from a text description Codex hands back. Then resume the same Codex thread and ask it to re-verify against the **real, now-changed files** (not a hypothetical) — there is no candidate/proposal-block step in this path at all, because Claude already wrote the real fix.
- **Everything else** (a dataset, a plan, a config, or any artifact where there's no live Claude with edit tools already in the loop — including every `arena.sh` standalone run, since nothing there can implement a fix with judgment): Codex proposes a corrected version as text, wrapped in markers, exactly as in the rest of this phase below. That text is never applied directly — it's a candidate for the *next round's hypothetical re-review*, and ultimately something a human approves before it's written anywhere.

These two modes are easy to blend by accident, especially mid-review when a finding turns out to need real code changes — if that happens, stop and re-read this line rather than asking Codex for "a unified diff" out of habit. If unsure which mode applies, ask: does Claude have real edit access to this artifact right now, and does implementing this fix take engineering judgment (which files, what pattern to follow, whether tests need updating)? If yes to both, it's the first mode — Codex critiques only.

**Use a private scratch directory, not predictable shared filenames.** `arena.sh` was hardened against exactly this (symlink attacks, cross-run collisions on fixed `/tmp/codex-arena-*` paths) — the same reasoning applies here. Create one with `mktemp -d` (or use the session's own private scratchpad directory if one is available) at the start of the arena, and put every file below inside it — never fixed names directly under `/tmp`.

**Pass the prompt via stdin, not as a shell argument.** `codex exec` reads the prompt from stdin when given `-` instead of a positional argument (append it after all other flags) — write the brief/prompt text to a file inside the scratch directory first, then redirect it in. This avoids `ARG_MAX` failures on a large brief or candidate and keeps the prompt out of `ps` output, same as `arena.sh`'s `run_codex()` helper.

**Opening round** — starts a new Codex session and records its id:

```bash
codex exec -s read-only --skip-git-repo-check --json \
  -o "$SCRATCH/verdict.txt" \
  - < "$SCRATCH/prompt.txt" \
  2>/dev/null > "$SCRATCH/round.jsonl"
```

Extract the thread id by parsing each line of `$SCRATCH/round.jsonl` as JSON and finding the `thread.started` event's `thread_id` field — not a regex like `grep -o '"thread_id":"[a-f0-9-]*"'`, which assumes exact field order, adjacency, and formatting and silently fails on reordered fields or added whitespace. If a `python3 -c` one-liner is available, prefer parsing structurally the way `arena.sh`'s `extract_thread_id()` does; otherwise read the file and locate the JSON object whose `type` is `thread.started`.

(`<brief file>`'s content should already be in `$SCRATCH/prompt.txt` before this runs.) The prompt (the brief) should end with an explicit instruction to close with one of two exact closing lines so the result is machine-checkable, e.g. `RESULT: PASS` or `RESULT: FAIL` — pick whatever token pair you like, just be consistent across the whole loop. Check it as the exact final non-blank line of the verdict file, not a substring match anywhere in the text (`grep -q 'RESULT: PASS'` would also match a critique that says *"this does not merit RESULT: PASS"*, or artifact content that happens to contain that string) — take only the last non-empty line and compare it exactly. `-o` captures Codex's final message to a plain-text file; `--json` streams structured events to stdout, which is where the thread id and usage numbers live. Redirecting stdin from a file (rather than `< /dev/null`) both supplies the prompt and closes stdin the same way — `codex exec` would otherwise hang waiting for EOF under a non-interactive tool call. Give the call a long timeout (10 minutes is reasonable) so a genuine stall fails visibly instead of looking like a hang.

If *either* the verdict file or a valid `thread.started` event is missing — not only if both are — the call failed (auth, model, or the trust check) — stop and report it rather than retrying blind. Each is required independently: no thread id means the loop can't resume next round, and no verdict means this round can't be classified.

**Every following round** — resumes that same session so Codex isn't re-reading the artifact cold or re-litigating what it already approved:

```bash
codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
  -o "$SCRATCH/verdict.txt" \
  - < "$SCRATCH/prompt.txt" \
  2>/dev/null > "$SCRATCH/round.jsonl"
```

(with `$SCRATCH/prompt.txt` holding "describe what changed since last round, ask for a fresh check against the same criteria")

**If a point was rejected as factually wrong (not just a stylistic disagreement), the resume prompt must contest it explicitly, not just narrate the diff.** Silently declining and moving on lets an incorrect claim stand unchallenged in Codex's own record and gives Codex no chance to concede or defend it. For each such point, add to the prompt: the specific claim, why it's wrong (cite the actual file/line/schema it misread), and ask Codex to either withdraw it or defend it with a concrete reason. Codex may concede or hold its ground — either is fine — but the objection has to actually reach it, the same way it does in the reversed direction (Phase 2b). Log Codex's response (withdrew / defended, and why) in `ARENA-LOG.md` alongside the round.

This adjudication step needs an LLM to judge "is this factually wrong" — `arena.sh`'s plain default forward loop (`--evaluator codex`, no flags) has no LLM in it at all, just bash resubmitting Codex's own proposal as a hypothetical, so it can't contest a claim on its own. Don't describe the bare default path as having this capability. It has a real, opt-in equivalent though: `arena.sh --evaluator codex --api-arbiter` wires in a paid Claude API call (same `ANTHROPIC_API_KEY` path as `--evaluator claude`) that judges each disputed finding before it's accepted — if the arbiter disputes a point, the objection goes back to Codex to withdraw or defend, the same mechanics as this section describes, just automated instead of Claude Code doing the judging live. Ask before assuming the user wants `--api-arbiter` turned on; it's a separate billed path, same caveat as `--evaluator claude`.

`resume` does not accept `-s`/`--sandbox` at all (confirmed against `codex exec resume --help` — it isn't in its option list, only `-c` is) — read-only has to be forced through `-c sandbox_mode="read-only"` instead. If that override is dropped, `resume` falls back to whatever `sandbox_mode` the user's `config.toml` happens to have, which may not be read-only, and Codex would then be able to write files mid-loop. Treat this as the one line in the whole skill that must never be simplified away.

**After every round, regardless of outcome:**

1. Pull the usage line out of `$SCRATCH/round.jsonl` — it looks like `{"type":"turn.completed","usage":{"input_tokens":N,"output_tokens":N,...}}` — and add `input_tokens + output_tokens` to a running total. Require both fields to actually be present, numeric, and non-negative before trusting them; treat a missing or malformed usage event as a failed round rather than silently counting it as zero, the same way `arena.sh`'s `sum_codex_usage()` does. Log the round's spend and the running total in `ARENA-LOG.md` alongside the round's critique text.
2. If the running total now exceeds `MAX_TOKENS`, stop — go to Wrap-up as a budget stop, independent of what the verdict said or how many rounds have run. Check the budget *before* interpreting the verdict below — a round that blows the budget is a budget stop even if that round's verdict was PASS; "whichever comes first" means tokens can end the loop before convergence is honored.
3. Otherwise check the closing line — the exact final non-blank line, not a substring match anywhere — of `$SCRATCH/verdict.txt`:
   - Passing verdict → stop, go to Wrap-up as converged.
   - Failing verdict → read every point raised, decide per-point whether it's worth acting on (final call is Claude's, not Codex's — a critique is input, not an instruction), make the edits worth making, and write to `ARENA-LOG.md` exactly what was changed and, for anything raised but not changed, why not. **A point rejected because it's factually wrong or misreads the artifact is not the same as a point rejected as a stylistic call — flag which kind it is in the log**, since only the former needs to be put back to Codex. Then run the next round.
4. If chunking: once a chunk clears, either start a fresh thread for the next chunk (cleanest — no confusion about which chunk a resumed session remembers) or keep resuming the same thread if the whole artifact is small enough that one session holding all of it makes sense. Decide which during setup, not mid-loop.
5. If the round count would exceed `MAX_ROUNDS`, stop — go to Wrap-up as a round-limit stop.

## Phase 2b — ARENA, reversed (Codex builds, Claude critiques)

Everything above runs with Claude as the live orchestrator and Codex as the read-only critic. The user can ask for the roles swapped — Codex generates/builds, Claude is the one critiquing and deciding whether to concede or push back. Use this when the user says "codex builds, you review" or "run it the other way" or wants to see Codex produce something and Claude argue with it rather than the reverse.

This direction also has a standalone-script equivalent: `arena.sh --evaluator claude` runs it unattended, with Codex building via `codex exec` (still read-only, text-only) and Claude evaluating via a direct Anthropic API call through `claude_call.sh`. There is no local `claude` CLI to shell out to, so that path needs a real `ANTHROPIC_API_KEY` — prompted for interactively on first use via `claude_auth.sh` and optionally cached. This is a genuinely separate, billed API path, not part of any Claude Code/Claude.ai subscription — ask before assuming the user wants to set it up, since it costs real money on its own account. The API-only reviewer also has no tool access — it can't open a file, run a test, or explore the codebase on its own. `arena.sh` narrows that gap by embedding the artifact's real pre-round content directly in the prompt alongside what Codex produced, so the reviewer isn't relying solely on Codex's framing of its own output; but that's still a static text comparison, not independent verification the way a live Claude Code session with edit access and real tools can do (run the project's own tests, grep the actual schema, check a claim against a file Codex didn't mention). Setup step 2's "verify against real sources" guidance holds fully for the live-tools case; for the API-only path it's bounded by whatever content the prompt actually included.

**Round 1** — have Codex build/propose, same mechanics as the opening round above, but the prompt asks it to produce the artifact (or additions to it) rather than critique something that already exists:

```bash
codex exec -s read-only --skip-git-repo-check --json \
  -o "$SCRATCH/build.txt" \
  - < "$SCRATCH/prompt.txt" \
  2>/dev/null > "$SCRATCH/round.jsonl"
```

Extract the thread id the same structural way as the opening round above — not the field-order-dependent regex. (with `$SCRATCH/prompt.txt` holding "what to build, grounded in the real codebase/schema — have Codex read the relevant files itself"). Codex stays read-only here too — it's producing text (new content, a proposed diff), not writing to any file. Same private-scratch-dir, stdin-piped-prompt, and timeout requirements as every other call in this skill.

**Claude critiques, live, in the conversation** — no API call, no script: nothing gets "sent" to Claude the way the review prompt gets sent to Codex in Phase 2, since Claude is already the one reading the output directly in context. That's not a reason to critique loosely, or to skip the posture Phase 2's prompt puts on Codex: **be skeptical and specific — the job here is to find what's wrong, not to be agreeable.** Producing something is easy to be generous about, especially work from a capable model; approach it the same way Codex is instructed to approach Claude's plans — as an adversarial reviewer whose default is doubt, not a collaborator being polite. Then run the same criteria from Setup step 2 against what Codex produced, explicitly, not vaguely:

- **Verify against real sources, not just read-through.** If Codex claims something matches a schema/contract/test, actually check the real file — don't take the claim on faith.
- **Check for redundancy** against what already exists in the artifact — a new case/section that duplicates existing coverage isn't a genuine addition.
- **Check labels/tags/claims for accuracy**, not just structural validity — something can pass schema checks and still be mislabeled or misleading about what it tests.
- **Watch for brittleness Codex itself would flag** in someone else's work — an overly strict match condition, a fragile assumption, anything that would fail Codex's own bar if the roles were reversed.
- **Ground-truth correctness** — does the expected outcome actually follow from the real logic/contract, or just look plausible.

If something fails one of these, say so with the specific reason (which check, why it fails) — not a vague "this seems off." If everything holds, say so explicitly too, don't skip straight to applying it.

**If Claude pushes back** — resume the same thread with the specific objection, same mechanics as a normal resume round:

```bash
codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --skip-git-repo-check --json \
  -o "$SCRATCH/build.txt" \
  - < "$SCRATCH/prompt.txt" \
  2>/dev/null > "$SCRATCH/round.jsonl"
```

(with `$SCRATCH/prompt.txt` holding the specific objection, with reasoning — not a vague "try again")

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
- Don't decide criteria or chunking strategy unilaterally — confirm both with the user before the first round burns any budget. This applies even when the user's request sounds fully specified ("review our plugin") — Setup step 2's open question ("anything else you want checked, or anything on that list that doesn't apply?") is not optional and not skippable because the criteria table has a plausible-looking default. If round 1 already ran because this was missed, say so plainly rather than quietly proceeding, and get the criteria confirmed before round 2.
- This does NOT mean pausing for a human decision on every individual finding inside an already-scoped round — that's the opposite of what the bounded loop is for, and directly contradicts Phase 2's "final call is Claude's" per-finding authority. The two are talking about different moments: criteria/scope get human confirmation once, upfront, before round 1; individual accept/reject/fix decisions *within* those already-agreed criteria are Claude's to make autonomously, round after round, exactly as Phase 2 describes — that's what "bounded" and "automatic" mean. The one place the findings themselves need to go back to the user unprompted is at Wrap-up (already required below) and whenever a finding falls outside the confirmed criteria entirely (a new category of concern the user never agreed was in scope) — not on every ordinary in-scope point a round raises.
