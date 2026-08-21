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

## License

MIT
