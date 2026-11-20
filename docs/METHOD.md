# The verify-loop method

For people who direct coding agents (Claude Code, Codex, Gemini CLI) but do not read the code themselves. You cannot review the diff, so the system has to.

The speakers did not review or endorse this document; any mistakes are ours.

Two ideas from two talks:
- **Limit what the agent can touch** (after [Lydia Hallie's talk](https://youtu.be/vlfCjWuv4es)): decide permissions by "can this be undone?", sandbox the rest, and make hooks block for real.
- **Push corrections down the pyramid** (after [Lauren Tan's talk](https://youtu.be/O_zcc6Xl12g)): fix a mistake at the cheapest layer that makes it impossible to repeat. Write a text rule only when nothing else can catch it.

Lauren Tan's inverted pyramid, cheapest and most trusted first:
1. Codebase design (APIs, folder boundaries, banned patterns)
2. Static analysis (types, lint, compiler, tests, CI)
3. Verification (drive the running app; formal models for state and timing)
4. Prose (AGENTS.md, CLAUDE.md, skills)
5. Human review

## 1. When something goes wrong, ask in order

1. **Is it a permission, not a mistake?** (who may deploy, who may merge) → enforce it with deny rules or branch protection; `AGENTS.md` only records who decides. A prompt alone does not enforce anything.
2. **Is it irreversible?**
   - Never allowed → deny rules plus the OS sandbox. Run Codex only through `tools/codex-dispatch.sh` (no full access, network off by default). Do not put agent launchers (`codex *`, `gemini *`), `osascript *` or `docker *` in `sandbox.excludedCommands`: an excluded command runs outside the sandbox, and exclusion is not a security boundary.
   - Allowed only under a condition (migrate only after a fresh backup) → a script with a precondition that refuses otherwise.
3. **Can a machine tell right from wrong?** Walk the pyramid as a correction tree (our arrangement of Lauren Tan's pyramid) and stop at the first rung that works. Write one line on why the rung above could not. Design for the next agent: it sees only the files it opens, copies the nearest example, and takes the shortest path that compiles.
   1. Redesign so the mistake cannot exist (ban the API, add a folder boundary, an import ban, a file-name convention such as `*.hot.ts` for code that runs every tick). Give each piece of state one owner, replace hand-synced lists with a single source, and delete old patterns and dead code that agents would copy.
   2. A type.
   3. A lint rule whose error message names the fix. Few old instances → remove them in the same change. Many → the rule blocks only new ones, and a separate change cleans the old (§3: prevent new mistakes first).
   4. A test. Test outcomes and invariants, not how the code looks. An existing test that passes when the behaviour is broken, or fails on an internal-only change, gets a separate test-only change that fixes or deletes it.
   5. A step in the feature map that drives the real app.
   Prove each new check: put a real past mistake back, see the check fail, remove it, see it pass. Local runs and CI run the same command. Run it alone twice and time it; a killed run must not leave files in the repo.
   - **State and timing bugs** (several devices, rooms, reconnects, schedules, payments): ordinary tests miss interleavings. Model the flow in TLA+, lock the key property in as a repo check, and draw it as a statechart for the human. Pure algorithms with invariants (scoring, sorting): consider a Lean proof. Start with one flow per project. Keep the model in sync with the code or delete it.
   - **A text rule already existed and the mistake happened anyway** → count it as a repeat. Fix it one rung higher in the same change; the text rule did not hold.
   - **Taste** (too wordy, looks generated) → `DESIGN.md` plus screenshots, video or audio for the human.
4. **Is it just how to do a task?** → a skill or a script. Project rules go in the repo, where every agent can read them.

Hooks: a failed check must `exit 2` (exit 1 counts as done). A hook timeout means nothing was checked, so the Stop hook keeps its own deadline below the hook timeout. A failure or an unfinished run blocks once per exact state; after that Claude may stop and sees NOT VERIFIED. Every verdict is appended to `~/.claude/state/stop-verify/ledger.tsv` (local, no paths). Checks wait while a subagent, workflow or `codex-dispatch.sh` runs and happen at the next stop. Two earlier layers use the same projects file: a PostToolUse hook runs a quick check after each edit and blocks when the check fails and an output line names the edited file (it does not parse the diagnostic format), and the `SubagentHandback` and `SubagentStop` hooks share the check for the same agent and checkout state. A successful hand-back tool result confirms delivery. Stop reports any checkout state left unverified after delivery. On a stop-only host, Stop runs the checks and blocks a failure. If the hook itself is broken (no `jq`), it exits 0 with a warning and never traps the session.

## 2. Who looks at what

- The human looks at **artifacts**, not code: before/after screenshots, short videos, statecharts, "failed before the fix, passes after" logs. Use the fixed names from the project's feature map.
- **Evidence rule**: every "done" or "passes" comes with the command and its output, or an artifact path. No evidence means not done.
- **Independent review of regression tests** (from a reader’s comment).
  - For normal changes, the implementer can add the regression test. An independent reviewer checks that the test fails on the old behavior and passes on the fix. For high-risk changes, a different agent writes the failing test and commits it separately before implementation. The reviewer checks the commit order.
  - A change that fixes code may not edit the existing tests that judge it. The Stop hook's test guard blocks it (uncommitted code and existing-test edits together → exit 2; committed ones are listed by the evidence script for the reviewer); new test files are fine. If a test is really wrong, that is a separate test-only change, approved by another agent or a human.
  - Evidence is tied to a commit: the PR's verification section comes from `tools/verify-evidence.sh` (commit SHA, command, exit code, log hash, and, with `--tests-re <test paths>`, whether existing tests changed), not from the agent's own words. Reviewers check that the SHA is the PR head.
  - Merging needs a human or an independent reviewer to approve that same SHA. The local guard stops mistakes, not deliberate bypasses; hard enforcement needs CI plus branch protection, with test folders in `CODEOWNERS` so a PR that edits tests needs an owner's review (agents must push from a separate account).
- Risk tiers (adapted from Lydia Hallie's one reviewer for normal changes, two for risky ones): copy and docs → green checks are enough. Normal changes → one review by a session that did not write the code. Money, login, store submission, deleting data → two independent reviews plus a working rollback or feature flag. If someone who reads code is available, they are one of the two.

## 3. Prune rules

Code comments are prose too, and agents copy them. In Lauren Tan's talk, one `setTimeout` workaround grew into 183 timers, and her slide on comments as liabilities shows them falling from 65,824 to 1,227. Start with a lint rule that bans new comments outside an allowlist. When a rule becomes a test or a script, delete the text version. Keep one copy of each rule. Delete instructions written for older models (Lydia Hallie). Prevent new mistakes first, then clean old code: agents copy whatever is there.

## 4. Two numbers a week (in `plans/FINDINGS.md`)

1. Repeats: review findings of a kind seen before. This should fall.
2. Interventions: how often the human was pulled in per task (approvals, pasted commands, questions). This falling is what "letting go" means.

## 5. Adoption order (start with the first missing step)

1. Tests that run, plus CI.
2. A Stop hook that runs the tests and blocks with exit 2.
3. Deny rules, the sandbox where possible, Codex through the dispatch script.
4. `AGENTS.md` permissions section, `DESIGN.md` taste section, a feature map.
5. Start the findings ledger.
6. Then run one task much bigger than usual and note where you were pulled back in. Those steps are your next checks.

Don't automate a bad loop (Lauren Tan): first reach "the agent writes good code and the agent verifies it". Do not turn on overnight or orchestrator modes before steps 1–4.
