# verify-loop

**A verification workflow for people who direct coding agents but do not read the code.**

If you build software by talking to Claude Code, Codex or Gemini CLI, you cannot review the diff yourself. So the system has to: hooks that run your tests before the agent may stop, permissions decided by "can this be undone?", and every repeated mistake turned into a check instead of another line in `AGENTS.md`.

[繁體中文說明](README.zh-TW.md) · [The method](docs/METHOD.md) · [Credits](CREDITS.md)

## What's inside

| Piece | What it does |
|---|---|
| `skills/verify-loop` | Say "verify". The model picks a mode: **start** (agree on 3–5 checkpoints first), **setup** (audit a repo's guardrails), **map** (feature map + a CLI that drives the real app), **triage** (turn a mistake into a check), **done** (evidence, blast radius, risk-tiered review). |
| `skills/debug` | Say "debug". The model routes: ordinary bug, performance, state/timing, or blast radius. |
| `hooks/stop-verify.sh` | A Stop hook. When the agent tries to finish in a registered repo with changed code, it runs that repo's checks. Fail or timeout → `exit 2`, the agent must keep working (max 3 blocks). With `tests_re` set, it also blocks a change that edits code and existing tests together. Its own errors never trap the session. |
| `tools/codex-dispatch.sh` | Runs `codex exec` with an allowlist of flags only: read-only or workspace-write, network off by default, no user config (no MCP servers, no notify hooks), the report file only under `<repo>/.scratch/` or a temp folder. |
| `tools/verify-evidence.sh` | Runs a check and prints a Markdown evidence block tied to the commit: SHA, command, exit code, log hash, and whether existing tests changed. Refuses a dirty tree. |
| `docs/METHOD.md` | The method in one page. |

## Install

### As a Claude Code plugin
```
/plugin marketplace add hank840214-alt/verify-loop
/plugin install verify-loop@verify-loop
```
The plugin registers the Stop hook. It does nothing until you register a project.

### Register a project for the Stop hook
Copy `examples/stop-verify.projects.json` to `~/.claude/stop-verify.projects.json` and edit it. The key is `owner/repo` from your `origin` remote (for `git@github.com:alice/shop.git` it is `alice/shop`), so a different owner's clone with the same name never matches.

```json
{
  "your-name/my-web-app": {
    "code_re": "^((src|tests)/.*\\.(ts|tsx|css|json)|package\\.json)$",
    "verify": "npx tsc --noEmit && npm test --silent",
    "requires": "node_modules",
    "limit": 300
  }
}
```

Before you register a project, read what its tests do. If they reset a database, point `verify` at a throwaway one (see `my-db-app` in the example).

Try it without running anything (from a clone of this repo, inside your project folder):
```
printf '{"cwd":"%s","session_id":"t"}' "$PWD" | STOP_VERIFY_DRY=1 bash /path/to/verify-loop/hooks/stop-verify.sh
```
It prints `[dry] ...` when your project is registered and has changed files; no output means "not registered" or "nothing changed".

### Codex dispatch
```
tools/codex-dispatch.sh -f task.md -s workspace-write -C /path/to/repo -o /path/to/repo/.scratch/report.md
# -o must be a new .md/.txt file under <repo>/.scratch/, /tmp or $TMPDIR
DRY_RUN=1 tools/codex-dispatch.sh ...   # print the command only
```
Then deny direct `codex` calls so agents are steered to the wrapper. See `examples/settings.snippet.json`. Copy the wrapper to a stable path first; the plugin's own folder changes on every update.

## Requirements
macOS or Linux, `bash`, `jq`, `perl`, `git`, `shasum`. Codex CLI for the dispatch script. Tested with Claude Code 2.1.326 and Codex CLI 0.164.0.

## Tests
```
bash tests/run.sh
```

## Limits — read these
- The Stop hook runs your test command with your user's permissions, outside Claude Code's sandbox. The agent can edit `package.json` or the tests, and the hook will then run them. Only register repos you trust, and review changes to test scripts.
- The hook fires whenever a registered repo has changed code, including your own unfinished work. Claude is told to stop, not edit, when the failures are not from its session, but it may still try.
- Codex in read-only mode can still read any file your user can read. The wrapper limits writes and network, not reads.
- Deny rules steer agents away from calling `codex` directly; they are not a sandbox.
- `excludedCommands` is a convenience, not a security boundary.
- This is a workflow, not a guarantee. It reduces how often you must read code; it does not make reading code unnecessary for high-risk changes.

## License
MIT. Inspired by talks from Lydia Hallie and Lauren Tan, with some skill steps adapted from Lauren Tan's MIT-licensed pstack; not affiliated with or endorsed by them. See [CREDITS](CREDITS.md).
