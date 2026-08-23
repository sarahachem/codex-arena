# codex-arena

A review loop between Claude Code and OpenAI's Codex CLI — one model critiques an artifact (a dataset, plan, diff, or config), the other decides what to fix, back and forth until it converges or a budget runs out. Neither model ever writes files directly.

Works two ways: conversationally in Claude Code (`/codex-arena`), or unattended via a script. You can pick which model reviews and which gets reviewed — and whichever one isn't the reviewer is the one that acts on findings, never the reviewer itself. In unattended mode, that "other model" role can be Claude over the Anthropic API instead of Codex, so a review isn't just one model grading its own work.

## How it works

1. **Point it at an artifact** — a dataset, plan, diff, or config file — and say what kind it is.
2. **Agree on criteria.** A short table of defaults comes up for that artifact type (e.g. for a dataset: schema validity, near-duplicates, label correctness); say what to add, drop, or leave as-is.
3. **The reviewer critiques it.** Whichever model you picked as reviewer reads the artifact against those criteria and reports what's wrong, or approves it.
4. **The other side responds.** If it's a real problem, the fix gets made (or proposed, if nothing has direct edit access). If the finding looks wrong, it gets contested back to the reviewer with a reason — not silently accepted or silently ignored.
5. **Repeat** until the reviewer approves, a round/token budget runs out, or the loop stalls (`arena.sh`: the exact same critique or candidate comes back two rounds in a row — stopped early as "stalled" rather than grinding through the rest of the round budget on a repeat).

**Example.** You generated a synthetic eval dataset with Claude and want a second opinion before trusting it. In Claude Code: `/codex-arena` → say you want to review `eval_cases.jsonl` → pick "dataset" → Claude and Codex agree on criteria (schema validity, duplicate rows, label correctness, edge-case coverage) → Codex critiques the file row by row → Claude fixes what holds up, pushes back on findings that don't (e.g. "this isn't a duplicate, the expected outputs differ"), and logs the reasoning either way → another round until Codex signs off.

## Two ways to use it

**Conversationally, with Claude Code.** Install the plugin, then say `/codex-arena` or ask Claude to review/generate something with it. Claude drives the loop, reads Codex's critiques, and can push back on findings it disagrees with, with the reason logged.

**Standalone.** `arena.sh` runs the whole loop unattended.

Those two modes reach Claude *differently*, and it affects review quality, not just cost:

- **Conversationally, Claude Code is the Claude in the loop.** It has your repo and real tools — it can open a file, run the project's tests, and check a claim Codex made against the actual source. No API call happens.
- **Standalone, there's no Claude Code session**, so `arena.sh` reaches Claude by HTTP request to the Anthropic API. That Claude is a single chat turn with **no tools and no repo access** — it sees only the text the script puts in the prompt. (`arena.sh` narrows the gap by pasting in the artifact's real content alongside whatever Codex said about it, so the reviewer isn't stuck with Codex's framing of its own work — but it still can't go look anything up.)

That's what "over the API" means in the table below.

**So for reviewing code, prefer the conversational mode** — it's both better and cheaper. If you do review a diff standalone, generate it with generous context (`git diff -U50 > review.patch`), because the reviewer sees the file you hand it and nothing else. A default 3-line-context diff gives it almost nothing to judge against.

One rule holds everywhere: **whichever model evaluates only ever judges** — it never writes the accepted fix. That's the other model's job. `--evaluator` picks who critiques; it has nothing to do with whether the artifact already exists (Codex reads and relays existing content either way).

Which mode you get depends on your credentials:

| | Who critiques | Who writes the fix | Anthropic API calls |
|---|---|---|---|
| `--evaluator codex`, no Anthropic credentials | Codex | Codex — it's the only model an unattended script can reach, so it self-reviews | None |
| `--evaluator codex`, credentials found | Codex | Claude, over the API — writes its own fix (not just accepting Codex's proposal), or disputes the finding back to Codex to withdraw or defend | Yes — consumes your inference budget |
| `--evaluator claude` | Claude, over the API | Codex — which also generates the artifact if it doesn't exist yet | Yes — consumes your inference budget |

The auth path (an `ant auth login` OAuth profile vs. an `ANTHROPIC_API_KEY`) changes how the script *authenticates*, not whether a call happens — both hit the same `/v1/messages` endpoint and both consume inference. Which bucket that draws from depends on your account; check the console if the specifics matter.

The middle row is **automatic, not a flag**: credentials are detected silently at startup — an `ant auth login` profile, `ANTHROPIC_ARENA_KEY`, or a key cached from a prior run. Authenticate once and every later `--evaluator codex` run picks it up on its own.

Because that's automatic, the script tells you before spending: it prints which credential source it found and exactly how to opt out of it (the opt-out differs — `ant auth logout` for a profile, unsetting the env var, or deleting the cache file). No billed call happens just from checking.

Two other flags worth knowing: `--init` asks for your criteria in plain English up front, and the run stops once at the very end to ask whether to write the result to disk, showing a diff first.

## Install

```bash
/plugin marketplace add sarahachem/codex-arena
/plugin install codex-arena@codex-arena
```

Then run the setup check (installs the Codex CLI if missing, verifies login):

```bash
bash ~/.claude/skills/codex-arena/setup.sh
```

## Requirements

- [Codex CLI](https://github.com/openai/codex) (`setup.sh` installs it via npm if missing)
- A Codex/ChatGPT login (`codex login` — interactive, `setup.sh` will tell you if it's missing)
- **Only if you use `arena.sh --evaluator claude`, or already have credentials available for the default `--evaluator codex` to auto-detect**: Anthropic credentials, resolved in this order —

  1. **An `ant auth login` OAuth profile** (recommended — nothing to create, paste, or store). Install the [Anthropic CLI](https://github.com/anthropics/anthropic-cli) (`brew install anthropics/tap/ant` on macOS) and run `ant auth login` once. `codex-arena` picks it up automatically and writes no secret to disk; the short-lived token is re-minted per request, so it can't expire partway through a long run.
  2. **An `ANTHROPIC_API_KEY`** from [console.anthropic.com](https://console.anthropic.com/settings/keys), via the environment or cached from a prior run.
  3. **An interactive prompt**, only the first time `--evaluator claude` runs with neither of the above.

  Either way these are **real API calls that consume your Anthropic account's inference budget** — OAuth removes the key-management step, not the spending. (Exactly which bucket they bill to depends on your account; check the console if that matters to you.) Nothing prompts otherwise, and no cost is incurred unless credentials end up available.

  **You can avoid this entirely by running the loop conversationally instead** (`/codex-arena` in Claude Code). There, Claude Code *is* the Claude in the loop — it reads Codex's critiques and writes the fixes directly, with no Anthropic API call and no extra spend. The API path exists because `arena.sh` runs unattended with no Claude Code session attached, so an API call is the only way it can reach a second model at all.

  > **Note:** because option 1 is auto-detected, running `ant auth login` for unrelated reasons will make a previously-free `--evaluator codex` run start spending on Claude adjudication. That's a better review, but it isn't free — `ant auth logout` (or running in a shell without the profile) opts back out.

## Standalone usage

```bash
# Ask for criteria in plain English, then run the full loop automatically:
arena.sh --init --artifact path/to/your/artifact

# Or supply a pre-written brief and run directly:
arena.sh --artifact path/to/your/artifact --brief ARENA-BRIEF.md --max-rounds 3

# If Anthropic credentials are already available (an `ant auth login`
# profile, an env var, or a key cached from a prior --evaluator claude run)
# this automatically has Codex only judge — a Claude API call writes
# every accepted fix. No flag needed; it's the same command as above, the
# behavior just depends on whether credentials are present:
arena.sh --artifact path/to/your/artifact --brief ARENA-BRIEF.md

# Pause and ask before each round's fix propagates, instead of running fully
# automatically — shows a diff, waits for [y/N], stops the run on a decline:
arena.sh --artifact path/to/your/artifact --brief ARENA-BRIEF.md --require-approval
```

See `skills/codex-arena/SKILL.md` for the full mechanics, safety rules (Codex never gets write access, ever), and the conversational flow Claude follows.

## How this compares

There are several other "adversarial AI review" tools out there. Most are narrower than a general artifact-hardening loop — a code-review tool, a design-doc critic, a manuscript stress-tester — though a couple stretch to cover code plus plans, or documents generally:

- [alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review), [pedronauck's skill](https://claudemarketplaces.com/skills/pedronauck/skills/adversarial-review), [agent-review-panel](https://github.com/wan-huiyan/agent-review-panel) — code (and code-adjacent plans), Codex vs. Claude or multi-persona panels
- [Adversarial Design Reviewer](https://mcpmarket.com/tools/skills/adversarial-design-reviewer) — technical design docs only
- [ecfm/adversarial-review](https://github.com/ecfm/adversarial-review) — academic manuscripts only
- [Adversarial Content Reviewer](https://mcpmarket.com/tools/skills/adversarial-content-reviewer) — general documents/logic, no dataset-specific checks
- [robertoecf/adversarial-review](https://github.com/robertoecf/adversarial-review) — code + plan validation bundled

Among the tools surveyed above, none cover datasets, plans, diffs, *and* config files under one mechanism — codex-arena is a single generic loop with a criteria table that swaps per artifact type, one tool instead of a different plugin per thing you're hardening. This is a snapshot comparison, not a maintained one; treat "none of them" as "none we found as of this writing," not a permanent claim. Codex never writes to a file in any mode — that part holds everywhere — but it does propose fixes as text outside the live-code path (see above), so "Codex only critiques" isn't a blanket description of the whole tool. In the conversational live-code path specifically, there's an explicit two-way objection step when Claude thinks Codex is factually wrong, rather than silently overruling it.

## License

MIT
