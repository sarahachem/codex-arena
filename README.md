# codex-arena

A review loop between Claude Code and OpenAI's Codex CLI — one model critiques an artifact (a dataset, plan, diff, or config), the other decides what to fix, back and forth until it converges or a budget runs out. Neither model ever writes files directly.

Works two ways: conversationally in Claude Code (`/codex-arena`), or unattended via a script. You can pick which model reviews and which gets reviewed — and whichever one isn't the reviewer is the one that acts on findings, never the reviewer itself. In unattended mode, that "other model" role can be a paid Claude API call instead of Codex, so a review isn't just one model grading its own work.

## How it works

1. **Point it at an artifact** — a dataset, plan, diff, or config file — and say what kind it is.
2. **Agree on criteria.** A short table of defaults comes up for that artifact type (e.g. for a dataset: schema validity, near-duplicates, label correctness); say what to add, drop, or leave as-is.
3. **The reviewer critiques it.** Whichever model you picked as reviewer reads the artifact against those criteria and reports what's wrong, or approves it.
4. **The other side responds.** If it's a real problem, the fix gets made (or proposed, if nothing has direct edit access). If the finding looks wrong, it gets contested back to the reviewer with a reason — not silently accepted or silently ignored.
5. **Repeat** until the reviewer approves, or a round/token budget runs out — whichever comes first.

**Example.** You generated a synthetic eval dataset with Claude and want a second opinion before trusting it. In Claude Code: `/codex-arena` → say you want to review `eval_cases.jsonl` → pick "dataset" → Claude and Codex agree on criteria (schema validity, duplicate rows, label correctness, edge-case coverage) → Codex critiques the file row by row → Claude fixes what holds up, pushes back on findings that don't (e.g. "this isn't a duplicate, the expected outputs differ"), and logs the reasoning either way → another round until Codex signs off.

## Two ways to use it

**Conversationally, with Claude Code.** Install the plugin, then say `/codex-arena` or ask Claude to review/generate something with it. Claude drives the loop, reads Codex's critiques, and can push back on findings it disagrees with, with the reason logged.

**Standalone.** `arena.sh` runs the whole loop unattended, and either model can end up as the critic — the flag picks who, not whether the artifact is new or already exists (Codex reads/relays existing content either way). The rule is consistent everywhere: whichever model evaluates only ever judges — it never writes the accepted fix, that's the other model's job. By default (`--evaluator codex`, no key) Codex is the only model reachable at all in an unattended script, so it necessarily judges *and* fixes itself — there's no other model to hand the fix to for free. Add `--api-arbiter` to change that: Codex still critiques, but now only ever critiques — a paid Claude API call writes every accepted fix (independently, not just accepting Codex's own proposed one) or disputes the finding and sends it back to Codex to withdraw or defend. `--init` asks you for criteria in plain English at the start, and it stops once, at the end, to ask whether to actually write the result to disk (with a diff shown first). There's also `--evaluator claude`, which flips the roles entirely: Codex reads (or, for a new artifact, generates) the content and does the fixing, and Claude is the one evaluating it via the same direct, separately-billed Anthropic API call (needs its own `ANTHROPIC_API_KEY`, not a Claude Code/Claude.ai subscription) — `--api-arbiter` and `--evaluator claude` are mutually exclusive, since `--evaluator claude` already has Claude as the evaluator.

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
- **Only if you use `arena.sh --evaluator claude` or `arena.sh --api-arbiter`**: a real `ANTHROPIC_API_KEY` from [console.anthropic.com](https://console.anthropic.com/settings/keys). This is a separate, billed API path — not covered by a Claude Code or Claude.ai subscription. `claude_auth.sh` prompts for it interactively the first time either mode runs and offers to cache it; nothing asks for it, and no cost is incurred, unless you actually use one of those two flags.

## Standalone usage

```bash
# Ask for criteria in plain English, then run the full loop automatically:
arena.sh --init --artifact path/to/your/file.json

# Or supply a pre-written brief and run directly:
arena.sh --artifact path/to/your/file.json --brief ARENA-BRIEF.md --max-rounds 3

# Same, but Codex only judges — a paid Claude API call writes every accepted fix:
arena.sh --artifact path/to/your/file.json --brief ARENA-BRIEF.md --api-arbiter
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
