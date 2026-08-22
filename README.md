# codex-arena

A bounded adversarial review-and-revise loop between Claude Code and the OpenAI Codex CLI. Codex critiques an artifact — a synthetic eval dataset, a plan, a diff, a config file — in a read-only sandbox and proposes fixes as plain text (never a file write). Claude (or you, running it standalone) decides what to act on. The loop runs automatically, round after round, until Codex approves or a round/token budget runs out.

## Two ways to use it

**Conversationally, with Claude Code.** Install the plugin, then say `/codex-arena` or ask Claude to review/generate something with it. Claude drives the loop, reads Codex's critiques, and can push back on findings it disagrees with, with the reason logged.

**Standalone, no Claude involved.** `arena.sh` runs the whole loop unattended — Codex critiques itself and proposes fixes, `--init` asks you for criteria in plain English at the start, and it stops once, at the end, to ask whether to actually write the result to disk (with a diff shown first).

## Install

```bash
/plugin marketplace add <your-github-username>/codex-arena
/plugin install codex-arena@codex-arena
```

Then run the setup check (installs the Codex CLI if missing, verifies login):

```bash
bash ~/.claude/skills/codex-arena/setup.sh
```

## Requirements

- [Codex CLI](https://github.com/openai/codex) (`setup.sh` installs it via npm if missing)
- A Codex/ChatGPT login (`codex login` — interactive, `setup.sh` will tell you if it's missing)

## Standalone usage

```bash
# Ask for criteria in plain English, then run the full loop automatically:
arena.sh --init --artifact path/to/your/file.json

# Or supply a pre-written brief and run directly:
arena.sh --artifact path/to/your/file.json --brief ARENA-BRIEF.md --max-rounds 3
```

See `skills/codex-arena/SKILL.md` for the full mechanics, safety rules (Codex never gets write access, ever), and the conversational flow Claude follows.

## How this compares

There are several other "adversarial AI review" tools out there, but each is scoped to one artifact type — a code-review loop, a design-doc critic, a manuscript stress-tester:

- [alecnielsen/adversarial-review](https://github.com/alecnielsen/adversarial-review), [pedronauck's skill](https://claudemarketplaces.com/skills/pedronauck/skills/adversarial-review), [agent-review-panel](https://github.com/wan-huiyan/agent-review-panel) — code (and code-adjacent plans), Codex vs. Claude or multi-persona panels
- [Adversarial Design Reviewer](https://mcpmarket.com/tools/skills/adversarial-design-reviewer) — technical design docs only
- [ecfm/adversarial-review](https://github.com/ecfm/adversarial-review) — academic manuscripts only
- [Adversarial Content Reviewer](https://mcpmarket.com/tools/skills/adversarial-content-reviewer) — general documents/logic, no dataset-specific checks
- [robertoecf/adversarial-review](https://github.com/robertoecf/adversarial-review) — code + plan validation bundled

None of them cover datasets, plans, diffs, *and* config files under one mechanism. codex-arena is a single generic loop with a criteria table that swaps per artifact type — one tool instead of a different plugin per thing you're hardening. It's also asymmetric by design (Codex only critiques, never writes; Claude owns every edit) with an explicit two-way objection step when Claude thinks Codex is factually wrong, rather than silently overruling it.

## License

MIT
