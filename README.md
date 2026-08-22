# codex-arena

A bounded adversarial review-and-revise loop between Claude Code and the OpenAI Codex CLI. Neither model ever writes to a file directly, in any mode — the closest either gets is proposing text that a human or Claude's own edit tools apply. The roles are configurable, not fixed: by default Codex critiques an artifact — a synthetic eval dataset, a plan, a diff, a config file — in a read-only sandbox, and Claude (either a live Claude Code session or, standalone, you) decides what to act on; reviewing live code with Claude Code attached, Claude implements the fix directly with its own edit tools instead of Codex proposing text. The roles can also be reversed — Codex builds or proposes an artifact, and Claude is the one critiquing it, live in conversation or via a separate Anthropic API call in standalone mode — see "Two ways to use it" below. The loop runs automatically, round after round, until the reviewer approves or a round/token budget runs out.

## Two ways to use it

**Conversationally, with Claude Code.** Install the plugin, then say `/codex-arena` or ask Claude to review/generate something with it. Claude drives the loop, reads Codex's critiques, and can push back on findings it disagrees with, with the reason logged.

**Standalone.** `arena.sh` runs the whole loop unattended. By default (`--evaluator codex`) no Claude is involved at all — Codex critiques an existing artifact and its findings are accepted as-is, carried into the next round unquestioned. Add `--api-arbiter` to change that: a paid Claude API call judges each disputed finding before it's accepted, and pushes back on Codex if it disagrees — same mechanism as the conversational contest step, just automated. `--init` asks you for criteria in plain English at the start, and it stops once, at the end, to ask whether to actually write the result to disk (with a diff shown first). There's also a fully reversed unattended mode, `--evaluator claude`: Codex builds instead of critiquing, and Claude evaluates via the same direct, separately-billed Anthropic API call (needs its own `ANTHROPIC_API_KEY`, not a Claude Code/Claude.ai subscription) — `--api-arbiter` and `--evaluator claude` are mutually exclusive, since `--evaluator claude` already has Claude arbitrating.

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

# Same, but with a paid Claude API call arbitrating disputed Codex findings:
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
