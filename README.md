# verify-loop

**A verification workflow for people who direct coding agents but do not read the code.**

If you build software by talking to Claude Code, Codex or Gemini CLI, you cannot review the diff yourself. So the system has to: hooks that run your tests before the agent may stop, permissions decided by "can this be undone?", and each mistake turned into a check instead of another line in `AGENTS.md`.

[繁體中文說明](README.zh-TW.md) · [The method](docs/METHOD.md) · [Credits](CREDITS.md)

## What's inside

| Piece | What it does |
|---|---|
| `skills/verify-loop` | Say "verify". The model picks a mode: **start** (set 3–5 checkpoints first), **setup** (audit a repo's guardrails), **map** (feature map + a CLI that drives the real app), **triage** (turn a mistake into a check), **done** (evidence, blast radius, risk-tiered review). |
| `skills/debug` | Say "debug". The model routes: ordinary bug, performance, state/timing, or blast radius. |
| `hooks/stop-verify.sh` | A Stop hook. When the agent tries to finish in a registered repo with changed code, it runs that repo's checks. A failure or a timeout blocks once per exact state (`exit 2`); the same state is not re-run, and after that Claude may stop and sees NOT VERIFIED. With `tests_re` set, it also blocks, once, a change that edits code and existing tests together; it sees uncommitted edits only (committed test edits are listed by `verify-evidence.sh` for the reviewer). Its own errors never trap the session. |
| `hooks/post-edit-check.sh` | A PostToolUse hook (`Edit`, `Write`, `MultiEdit`), layer 1. After an edit in a registered project that has an `edit_check`, it runs that quick check (for example `tsc`) and blocks (`exit 2`) only when the check fails and a line of its output names the file Claude just edited. Errors in other files are ignored. A timeout, a missing tool or its own error never blocks. |
| `hooks/subagent-verify.sh` | A PreToolUse hook for `SubagentHandback`, layer 2. When a subagent is about to hand in its report, it works out from the subagent's own transcript whether it changed a trusted checkout, and if so runs the project's checks. A failure blocks the hand-back (`exit 2`) and the subagent keeps fixing. At most 2 blocks per subagent, once per exact state. |
| `tools/codex-dispatch.sh` | Runs `codex exec` with an allowlist of flags only: read-only or workspace-write, network off by default for the commands Codex runs (the prompt and images still go to the model service; the caller can pass `--net`), no user config (no MCP servers, no notify hooks), workspace-write only in the current repo (or repos you list), the report file only under `<repo>/.scratch/` or `/tmp`. |
| `tools/verify-evidence.sh` | Runs a check and prints a Markdown evidence block tied to the commit: SHA, command, exit code, log hash, the `node` and `python3` it found on `PATH` (add more with `--tool <name>`; paths are masked, but read that line before posting), and whether existing tests changed. A test added in the branch and edited again is listed under its own heading. The script does not change `PATH`: if the tools line shows a shim or an old interpreter, fix `PATH` and rerun. Refuses a dirty tree; exits 90 (INVALID) if the tree changes during the run or test edits cannot be checked. It prints no log text unless you pass `--tail N`, but it does print the full command. Local evidence helps a reviewer; it cannot see a command that edits files and puts them back. The real gate is CI rerunning on that SHA in a clean checkout. |
| `docs/METHOD.md` | The method in one page. |

## Install

### As a Claude Code plugin
```
/plugin marketplace add hank840214-alt/verify-loop
/plugin install verify-loop@verify-loop
```
The plugin registers the Stop hook and the two new hooks. They do nothing until you register a project.

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

### Quick check after each edit, and a check before a subagent reports
Both hooks read the same projects file and use the same `roots` trust as the Stop hook. They are opt-in: a project without `edit_check` is left alone by layer 1, and a project without `handback_verify` is left alone by layer 2 (its Stop-hook `verify` is never run by layer 2). Each hook runs your command as your user, outside Claude Code's sandbox, at a time the Stop hook did not: layer 1 after every matching edit, layer 2 when a subagent that changed a checkout hands in its report. `$STOP_VERIFY_CONFIG` is used only when it is an absolute path.

```json
{
  "your-name/my-web-app": {
    "roots": ["/home/you/src/my-web-app"],
    "verify": "npx tsc --noEmit && npm test --silent",
    "edit_check": {
      "files_re": "^(src|server)/.*\\.(ts|tsx)$",
      "cmd": "npx tsc --noEmit --pretty false",
      "limit": 20
    },
    "handback_verify": "npx tsc --noEmit && npm test --silent",
    "handback_limit": 420
  }
}
```

- `edit_check` (layer 1): `files_re` is an extended regex on the repo-relative path; `cmd` is a bash command run at the repo root with `$EDIT_FILE` set to that path; `limit` is in seconds (1..22, default 20). The hook blocks only when `cmd` exits non-zero and some output line names the edited file, as a whole path (repo-relative or absolute). It shows at most 20 such lines. If `cmd` only reports other files, the edit passes. Make the tool print paths relative to the repo root. ANSI colour codes are stripped before matching and `NO_COLOR=1` is set. If `requires` is set and missing, the check is skipped. The matcher only asks whether an output line names the file; it does not parse the diagnostic format, so a status line that mentions the file next to an error in another file can still block.
- `handback_verify` (layer 2): the command run when a subagent that changed this checkout hands in its report. There is no fallback to `verify`; without this field layer 2 does nothing for the project. It fails when it exits non-zero. Exit 124, 126, 127 or a kill by signal means "not verified", and the hand-back goes through. `$VERIFY_CHANGED_FILE` lists the files the subagent wrote with the edit tools.
- `handback_limit`: seconds before that run is stopped as "not verified" (1..440, default 420; the hook timeout is 480).

Ledgers: `~/.claude/state/post-edit-check/ledger.tsv` and `~/.claude/state/subagent-verify/ledger.tsv` (local, never printed).

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
- Stops at the same time on one checkout can each run the checks and each block. A pass recorded by another session can hide this session's earlier failure of the same code.
- The hook fires whenever a registered repo has changed code, including your own unfinished work. Claude is told to stop, not edit, when the failures are not from its session, but it may still try.
- Layer 1 (`post-edit-check.sh`) runs after the edit. It cannot undo it; it only tells Claude. Only an output line that names the edited file blocks, so a tool that prints no paths never blocks.
- Layer 2 (`subagent-verify.sh`) needs the `SubagentHandback` tool, the one a subagent calls to hand in its report. It was observed on recent Claude Code. On a host without it, the hook never fires and nothing is checked.
- Layer 2 works on shared checkouts. A failure can come from another session's edit, so the block message says so and tells the subagent not to revert work that is not its own.
- Layer 2 finds a subagent's Bash writes by matching strings (`>`, `sed -i`, `mv`, `git checkout`, and so on) and path names. It can miss a write, and it can count a harmless command. Read-only git (`status`, `log`, `diff`, `show`, `stash list`) does not count.
- Layer 2 runs the whole `handback_verify` command, whatever file the subagent changed.
- Both hooks check trust, then start the command later. If someone swaps a linked worktree for a symlink in between, the command can run in the wrong place. That race is not defended against.
- Codex in read-only mode can still read any file your user can read. The wrapper limits writes and network, not reads.
- "Network off" is a Codex setting the wrapper passes (`sandbox_workspace_write.network_access=false`); the tests check the flag, not real traffic. Check it once on your Codex version.
- Evidence blocks are meant for PRs. They show the full command and, with `--tail N`, the end of the log. Keep secrets out of command arguments (use environment variables) and read the whole block before you post it publicly.
- The dispatch wrapper runs outside Claude's sandbox and starts `codex` from your `PATH`. It refuses a `codex` inside the target or current repo; keep other folders that agents can write off your `PATH`.
- Deny rules steer agents away from calling `codex` directly; they are not a sandbox.
- `excludedCommands` is a convenience, not a security boundary.
- This is a workflow, not a guarantee. High-risk changes (money, login, deleting data) need two independent AI reviews and a way to roll back; if someone who reads code is available, have them look too.

## Field notes

From the first real runs, on one app with a server and a browser client. The driver and its checks described below live in that project, not in this repo.

- "Each test passes alone" is not a conclusion. Read the failing log for a signal the system printed itself. Every failure had a guard's shutdown line just before it; that line was the root cause.
- Reproduce "the machine was busy" on purpose. Blocking the event loop inside the test process reproduced it; twenty idle-spinning CPU processes did not.
- Produce evidence with a clean `PATH`. Two full runs showed 44 and 39 false failures from an old system interpreter and from a shim.
- A new check can be flaky too. Keep only the one signal under test real, inject the rest, then put the old mistake back and see the check fail.
- A flow that passes is not proof until the screenshot shows what the feature map promises. One flow passed on internal state while the thing it claimed was off screen, and later while it sat under an overlay. In that project the check now requires the visible label, uncovered, before and after the shot.
- Drive the build your users get. The first driver built without the production feature flags, so four flows passed on screens no user sees.
- Tie the picture to the code. A screenshot stamped with a commit id must come from that commit. That project's driver stamps an uncommitted build `+dirty` and refuses a running instance built from another state.
- A verification tool that starts processes must prove a process is its own before it stops it. A recorded PID is not proof after a reboot; record the start time and command line too.
- Every one of these was found by an independent reviewer or by rerunning, not by the session that wrote the code.
- In the evidence block, a test added in the branch and edited again has its own heading; it is no longer called an existing test.

From the first day of the two edit and hand-back hooks, on the same project (two small ledgers, so treat these as early signs, not results):

- Unit tests are not enough for a hook; run it once in the real host. The first layer-2 version listened for the subagent's stop event and passed 212 unit tests. In real use it logged two failures and nothing was fixed: by the time the block arrived, the subagent had already handed in. Moving it to the hand-back tool call gave one full fail → fix → pass cycle.
- Set the time limit from runs on a busy machine. The full test suite took 133–226 s under load, against an estimated 100–130 s when idle. A first limit of 200 s meant every busy run ended as "not verified".
- A file the checker does not cover is skipped, not passed. That project's type-check config covered only two of its folders, so edits elsewhere were skipped, not checked (the private version that ran then logged them as `skip`).
- Most subagents change nothing. 11 of 17 layer-2 entries were read-only subagents, so the check cost them nothing.
- The quick check paid off at once: three blocks after an edit, each fixed by the next edit 4–6 s later. Each check took 2–6 s. No false blocks yet.

## License
MIT. Inspired by talks from Lydia Hallie and Lauren Tan, with some skill steps adapted from Lauren Tan's MIT-licensed pstack; not affiliated with or endorsed by them. See [CREDITS](CREDITS.md).
