# verify-loop

**A verification workflow for people who direct coding agents but do not read the code.**

If you build software by talking to Claude Code, Codex or Gemini CLI, you cannot review the diff yourself. So the system has to: hooks that run your tests before the agent may stop, permissions decided by "can this be undone?", and each mistake turned into a check instead of another line in `AGENTS.md`.

[繁體中文說明](README.zh-TW.md) · [The method](docs/METHOD.md) · [Credits](CREDITS.md)

## What's inside

| Piece | What it does |
|---|---|
| `skills/verify-loop` | Say "verify". The model picks a mode: **start** (agree on 3–5 checkpoints first), **setup** (audit a repo's guardrails), **map** (feature map + a CLI that drives the real app), **triage** (turn a mistake into a check), **done** (evidence, blast radius, risk-tiered review). |
| `skills/debug` | Say "debug". The model routes: ordinary bug, performance, state/timing, or blast radius. |
| `hooks/stop-verify.sh` | A Stop hook. When the agent tries to finish in a registered repo with changed code, it runs that repo's checks. A failure or a timeout blocks once per exact state (`exit 2`); the same state is not re-run, and after that Claude may stop and sees NOT VERIFIED. With `tests_re` set, it also blocks, once, a change that edits code and existing tests together; it sees uncommitted edits only (committed test edits are listed by `verify-evidence.sh` for the reviewer). Its own errors never trap the session. |
| `tools/codex-dispatch.sh` | Runs `codex exec` with an allowlist of flags only: read-only or workspace-write, network off by default for the commands Codex runs (the prompt and images still go to the model service; the caller can pass `--net`), no user config (no MCP servers, no notify hooks), workspace-write only in the current repo (or repos you list), the report file only under `<repo>/.scratch/` or `/tmp`. |
| `tools/verify-evidence.sh` | Runs a check and prints a Markdown evidence block tied to the commit: SHA, command, exit code, log hash, and whether existing tests changed. Refuses a dirty tree; exits 90 (INVALID) if the tree changes during the run or test edits cannot be checked. It prints no log text unless you pass `--tail N`, but it does print the full command. Local evidence helps a reviewer; it cannot see a command that edits files and puts them back. The real gate is CI rerunning on that SHA in a clean checkout. |
| `docs/METHOD.md` | The method in one page. |

## Install

### As a Claude Code plugin
```
/plugin marketplace add hank840214-alt/verify-loop
/plugin install verify-loop@verify-loop
```
The plugin registers the Stop hook. It does nothing until you register a project.

### Register a project for the Stop hook
Copy `examples/stop-verify.projects.json` to `~/.claude/stop-verify.projects.json` and edit it. The key is `owner/repo` from your `origin` remote (for `git@github.com:alice/shop.git` it is `alice/shop`), so a different owner's clone with the same name never matches. `roots` is required: the absolute paths of the checkouts you trust. Any other checkout, even of the same repo, is never run.

```json
{
  "your-name/my-web-app": {
    "roots": ["/home/you/src/my-web-app"],
    "code_re": "^((src|tests)/.*\\.(ts|tsx|css|json)|package\\.json)$",
    "verify": "npx tsc --noEmit && npm test --silent",
    "requires": "node_modules",
    "limit": 300
  }
}
```

Optional `skip_re` names files that never trigger a run (generated files, leftovers of killed tests). Each verdict is appended to `~/.claude/state/stop-verify/ledger.tsv` (local, never printed, no full paths). Checks are skipped while a subagent, workflow or `codex-dispatch.sh` is running and happen at the next stop. `STOP_VERIFY_DEADLINE` (120..540 s, default 540) is the total time budget. To force a re-run of a failed state, change a file or delete `<state dir>/<id>.red`. `VERIFY_CHANGED_FILE` is newline-separated, so file names with newlines are not supported.

Before you register a project, ask the agent to run `/verify-loop setup`. It reads the test setup and lists steps that reset a database, deploy, send mail or call paid APIs. If tests reset a database, point `verify` at a throwaway one (see `my-db-app` in the example).

Try it without running anything (from a clone of this repo, inside your project folder):
```
printf '{"cwd":"%s","session_id":"t"}' "$PWD" | STOP_VERIFY_DRY=1 bash /path/to/verify-loop/hooks/stop-verify.sh
```
It prints `[dry] ...` when your project is registered and has changed files. It prints `[dry] ... no changed files` when nothing changed. If the repo is registered but this checkout is not in `roots`, the hook always says so and prints the real path to add (the `pwd -P` form; `/tmp` is `/private/tmp` on macOS). Linked worktrees of a listed checkout are trusted. No output means the repo is not registered. The session's folder must be inside the repo.

### Codex dispatch
```
tools/codex-dispatch.sh -f task.md -s workspace-write -C /path/to/repo -o /path/to/repo/.scratch/report.md
# -o must be a new .md/.txt file under <repo>/.scratch/ or /tmp
DRY_RUN=1 tools/codex-dispatch.sh ...   # print the command only
```
Then deny direct `codex` calls so agents are steered to the wrapper. See `examples/settings.snippet.json`. Copy the wrapper to a stable path first; the plugin's own folder changes on every update. With `-s workspace-write`, `-C` must be the repo of the folder you run it from; to allow another repo, add its path to `~/.config/codex-dispatch/repos`.

### Hard stop on the server: CODEOWNERS for tests
The local test guard can be bypassed (commit first, then edit the tests). Let GitHub enforce it: copy `examples/CODEOWNERS` to `.github/CODEOWNERS` with your test paths and owner, and require a PR with Code Owner review on the default branch (administrators too). Agents must push from a separate account, because GitHub does not let an account approve its own PR. Free on public repos; private repos need a paid plan.

## Requirements
macOS or Linux, `bash`, `jq`, `perl`, `git`, `shasum`. Codex CLI for the dispatch script. Tested with Claude Code 2.1.326 and Codex CLI 0.164.0.

## Tests
```
bash tests/run.sh
```

## Limits — read these
- The Stop hook runs your test command with your user's permissions, outside Claude Code's sandbox. The agent can edit `package.json` or the tests, and the hook will then run them. Trust is by path: if you check out someone else's branch or PR in a listed checkout, the hook runs that branch's test scripts as you. Only register checkouts where you run code you trust, have `/verify-loop done` list changes to test scripts in the PR, and use a separate clone (not in `roots`) for outside PRs. To isolate the run, make `verify` start a container or VM yourself.
- The stop hook does not look for files hidden with skip-worktree/assume-unchanged; the evidence script still refuses them.
- The hook fires whenever a registered repo has changed code, including your own unfinished work. Claude is told to stop, not edit, when the failures are not from its session, but it may still try.
- Codex in read-only mode can still read any file your user can read. The wrapper limits writes and network, not reads.
- "Network off" is a Codex setting the wrapper passes (`sandbox_workspace_write.network_access=false`); the tests check the flag, not real traffic. Check it once on your Codex version.
- Evidence blocks are meant for PRs. They show the full command and, with `--tail N`, the end of the log. Keep secrets out of command arguments (use environment variables) and read the whole block before you post it publicly.
- The dispatch wrapper runs outside Claude's sandbox and starts `codex` from your `PATH`. It refuses a `codex` inside the target or current repo; keep other folders that agents can write off your `PATH`.
- Deny rules steer agents away from calling `codex` directly; they are not a sandbox.
- `excludedCommands` is a convenience, not a security boundary.
- This is a workflow, not a guarantee. High-risk changes (money, login, deleting data) need two independent AI reviews and a way to roll back; if someone who reads code is available, have them look too.

## License
MIT. Inspired by talks from Lydia Hallie and Lauren Tan, with some skill steps adapted from Lauren Tan's MIT-licensed pstack; not affiliated with or endorsed by them. See [CREDITS](CREDITS.md).
