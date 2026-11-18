# The verify-loop method

For people who direct coding agents (Claude Code, Codex, Gemini CLI) but do not read the code themselves. You cannot review the diff, so the system has to.

The speakers did not review or endorse this document; any mistakes are ours.

Two ideas carry the whole method:
- **Limit what the agent can touch** (after [Lydia Hallie's talk](https://youtu.be/vlfCjWuv4es)): decide permissions by "can this be undone?", sandbox the rest, and make hooks block for real.
- **Turn every correction into a check** (after [Lauren Tan's talk](https://youtu.be/O_zcc6Xl12g)): fix a mistake at the cheapest layer that makes it impossible to repeat. Write a text rule only when nothing else can catch it.

The inverted pyramid, cheapest and most trusted first:
1. Codebase design (APIs, folder boundaries, banned patterns)
2. Static analysis (types, lint, compiler, tests, CI)
3. Verification (drive the running app; formal models for state and timing)
4. Prose (AGENTS.md, CLAUDE.md, skills)
5. Human review

Don't automate a bad loop. First reach "the agent writes good code and the agent verifies it". Only then add automatic triggers (overnight runs, scheduled agents).

## 1. When something goes wrong, ask in order

1. **Is it a permission, not a mistake?** (who may deploy, who may merge) → write it in the repo's `AGENTS.md` under "needs human approval". No check needed.
2. **Is it irreversible?**
   - Never allowed → deny rules plus the OS sandbox. Run Codex only through `tools/codex-dispatch.sh` (no full access, network off by default). Do not put agent launchers (`codex *`, `gemini *`), `osascript *` or `docker *` in `sandbox.excludedCommands`: an excluded command runs outside the sandbox, and exclusion is not a security boundary.
   - Allowed only under a condition (migrate only after a fresh backup) → a script with a precondition that refuses otherwise.
3. **Can a machine tell right from wrong?** Walk the correction tree and stop at the first rung that works:
   1. Redesign so the mistake cannot exist (ban the API, add a folder boundary, an import ban, a file-name convention such as `*.hot.ts` for code that runs every tick).
   2. A type.
   3. A lint rule whose error message names the fix. In the same change, remove the old pattern everywhere.
   4. A test. Test outcomes and invariants, not how the code looks.
   5. A step in the feature map that drives the real app.
   Prove each new check: put a real past mistake back, see the check fail, remove it, see it pass.
   - **State and timing bugs** (several devices, rooms, reconnects, schedules, payments): ordinary tests miss interleavings. Model the flow in TLA+, lock the key property in as a repo check, and draw it as a statechart for the human. Pure algorithms with invariants (scoring, sorting): consider a Lean proof. Start with one flow per project. Keep the model in sync with the code or delete it.
   - **Taste** (too wordy, looks generated) → `DESIGN.md` plus screenshots, video or audio for the human.
4. **Is it just how to do a task?** → a skill or a script.
5. **Personal memory** holds only personal preferences and cross-project facts. Project rules go in the repo, where every agent can read them.

Hooks: a failed check must `exit 2` (exit 1 counts as done). A hook timeout means nothing was checked, so the Stop hook keeps its own deadline below the hook timeout and counts a timeout as a failure. It blocks at most 3 times. If the hook itself is broken (no `jq`), it exits 0 with a warning and never traps the session.

## 2. Who looks at what

- The human looks at **artifacts**, not code: before/after screenshots, short videos, statecharts, "failed before the fix, passes after" logs. Use the fixed names from the project's feature map.
- **Evidence rule**: every "done" or "passes" comes with the command and its output, or an artifact path. No evidence means not done.
- **Whoever writes the fix does not grade it.** One agent writing both the fix and its test is marking its own exam.
  - The failing test is written by a different agent from the one that writes the fix, and committed first on its own.
  - A change that fixes code may not edit the existing tests that judge it. The Stop hook's test guard blocks it (uncommitted code and existing-test edits together → exit 2; committed ones are listed by the evidence script for the reviewer); new test files are fine. If a test is really wrong, that is a separate test-only change, approved by another agent or a human.
  - Evidence is tied to a commit: the PR's verification section comes from `tools/verify-evidence.sh` (commit SHA, command, exit code, log hash, and, with `--tests-re <test paths>`, whether existing tests changed), not from the agent's own words. Reviewers check that the SHA is the PR head.
  - Merging needs a human or an independent reviewer to approve that same SHA. The local guard stops mistakes, not deliberate bypasses; hard enforcement needs CI plus branch protection.
- Four layers replace a code reviewer: tests plus CI, a fresh-context review by a strong model, a review by a different model family, and formal verification for account and state flows.
- Risk tiers: copy and docs → green checks are enough. Normal changes → one AI review by a session that did not write the code. Money, login, store submission, deleting data → two independent AI reviews plus a working rollback or feature flag.

## 3. Prune rules

Code comments are prose too. A comment that justifies a workaround gets copied by the next agent (an example from Lauren Tan's talk: one `setTimeout` workaround was copied into a shared module and multiplied into well over a hundred timers). Ban them with lint and delete them in review. When a rule becomes a test or a script, delete the text version. Keep one copy of each rule. Delete memory that no longer matches reality. Archive rules unused for 30 days. Prevent new mistakes first, then clean old code: agents copy whatever is there.

## 4. Four numbers a week (in `plans/FINDINGS.md`)

1. Escapes: problems found only after release.
2. Repeats: review findings of a kind seen before (should fall).
3. Cost: tokens per task, and the share spent on verification.
4. Interventions: how often the human was pulled in per task (approvals, pasted commands, questions). This falling is what "letting go" means.

## 5. Adoption order (fill gaps, do not climb)

1. Tests that run, plus CI.
2. A Stop hook that runs the tests and blocks with exit 2.
3. Deny rules, the sandbox where possible, Codex through the dispatch script.
4. `AGENTS.md` permissions section, `DESIGN.md` taste section, a feature map.
5. Start the findings ledger.
6. Then run one task much bigger than usual and note where you were pulled back in. Those steps are your next checks.

Do not turn on overnight or orchestrator modes before steps 1–4.
