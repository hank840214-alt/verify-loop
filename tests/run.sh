#!/usr/bin/env bash
# Self-contained tests. Uses a temporary HOME; never runs Codex or real test suites.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME/.codex"; unset XDG_STATE_HOME
printf 'model = "test-model"\nmodel_reasoning_effort = "low"\n[profiles.x]\nmodel = "other"\n' > "$HOME/.codex/config.toml"
pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
expect_rc() { local want=$1 name=$2; shift 2; "$@" >"$T/out" 2>&1; local rc=$?; [[ $rc == "$want" ]] && ok "$name" || { bad "$name (rc=$rc, want $want)"; sed 's/^/     /' "$T/out"; }; }

# ---------- codex-dispatch ----------
D="$ROOT/tools/codex-dispatch.sh"
REPO="$T/repo"; mkdir -p "$REPO/.scratch" "$T/plain"; git -C "$REPO" init -q
echo "do the thing" > "$T/task.md"
export DRY_RUN=1
expect_rc 65 "dispatch: unknown flag refused"            bash "$D" -f "$T/task.md" -s read-only -C "$REPO" --dangerously-bypass-approvals-and-sandbox
expect_rc 65 "dispatch: -c other than effort refused"    bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -c notify=x
expect_rc 65 "dispatch: danger-full-access refused"      bash "$D" -f "$T/task.md" -s danger-full-access -C "$REPO"
expect_rc 65 "dispatch: -C / refused"                    bash "$D" -f "$T/task.md" -s read-only -C / --skip-git-repo-check
expect_rc 65 "dispatch: -C HOME refused"                 bash "$D" -f "$T/task.md" -s read-only -C "$HOME" --skip-git-repo-check
expect_rc 65 "dispatch: workspace-write outside git"     bash "$D" -f "$T/task.md" -s workspace-write -C "$T/plain"
expect_rc 65 "dispatch: skip-git-check needs read-only"  bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" --skip-git-repo-check
expect_rc 65 "dispatch: -o must be .md/.txt"             bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/x.py"
expect_rc 65 "dispatch: -o in dot folder refused"        bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.git/x.md"
ln -s "$T/elsewhere.md" "$REPO/.scratch/link.md"
expect_rc 65 "dispatch: -o symlink refused"              bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/link.md"
mkdir -p "$HOME/.claude/r"; git -C "$HOME/.claude/r" init -q
expect_rc 65 "dispatch: workspace-write in ~/.claude"    bash "$D" -f "$T/task.md" -s workspace-write -C "$HOME/.claude/r"
expect_rc 65 "dispatch: read-only -C ~/.claude refused"  bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$HOME/.claude" -o "$HOME/.claude/CLAUDE.md"
expect_rc 65 "dispatch: -o in repo root refused"         bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/AGENTS.md"
echo old > "$REPO/.scratch/exists.md"
expect_rc 65 "dispatch: -o existing file refused"        bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/exists.md"
expect_rc 65 "dispatch: --net with read-only refused"    bash "$D" -f "$T/task.md" -s read-only -C "$REPO" --net
expect_rc 65 "dispatch: -m starting with - refused"      bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -m --oss
inrepo() { (cd "$REPO" && "$@"); }
expect_rc 0  "dispatch: valid call (from inside the repo)" inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" -o "$REPO/.scratch/r.md"
grep -q -- '--ignore-user-config' "$T/out" && grep -q 'network_access=false' "$T/out" && grep -q 'test-model' "$T/out" && ! grep -q other "$T/out" \
  && ok "dispatch: no user config, network off, model from top-level config" || bad "dispatch: command shape"
inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$REPO" --net >"$T/out" 2>&1
grep -q 'network_access=true' "$T/out" && ok "dispatch: --net turns network on explicitly" || bad "dispatch: --net"
O2="$T/other"; mkdir -p "$O2"; git -C "$O2" init -q
expect_rc 65 "dispatch: workspace-write -C of a repo you are not in is refused" inrepo bash "$D" -f "$T/task.md" -s workspace-write -C "$O2"
grep -q 'repo of the current folder' "$T/out" && ok "dispatch: says why (-C not the current repo)" || bad "dispatch: -C message"
DF="$T/dotfiles"; mkdir -p "$DF"; git -C "$DF" init -q; ln -s "$HOME/.claude" "$DF/claude-link"
expect_rc 0 "dispatch: read-only -C of another repo is fine" inrepo bash "$D" -f "$T/task.md" -s read-only -C "$O2"
REALHOME="$(perl -e 'print((getpwuid($<))[7])')"
expect_rc 65 "dispatch: HOME=elsewhere cannot unprotect the real ~/.claude" env HOME="$T" bash "$D" -f "$T/task.md" -s read-only --skip-git-repo-check -C "$REALHOME/.claude"
unset DRY_RUN
mkdir -p "$T/bin"; cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
o=""; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done
cat >/dev/null; [[ -n "$o" ]] && echo "fake report" > "$o"; exit 0
FAKE
chmod +x "$T/bin/codex"
PATH="$T/bin:$PATH" expect_rc 0 "dispatch: real run delivers -o via private staging" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/real.md"
grep -q "fake report" "$REPO/.scratch/real.md" && ok "dispatch: report delivered" || bad "dispatch: report missing"
mkdir -p "$T/outside"; mv "$REPO/.scratch" "$T/outside/s"; ln -s "$T/outside/s" "$REPO/.scratch"
expect_rc 65 "dispatch: .scratch symlink refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/x.md"
rm "$REPO/.scratch"; mv "$T/outside/s" "$REPO/.scratch"
cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
o=""; while (($#)); do [[ "$1" == -o ]] && o="$2"; shift; done
cat >/dev/null; echo "partial report" > "$o"; exit 1
FAKE
PATH="$T/bin:$PATH" expect_rc 1 "dispatch: Codex failure keeps its exit code" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/fail.md"
grep -q "partial report" "$REPO/.scratch/fail.md" && ok "dispatch: report still delivered when Codex fails" || bad "dispatch: report lost on failure"
echo victim > "$T/victim.txt"
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
o=""; while ((\$#)); do [[ "\$1" == -o ]] && o="\$2"; shift; done
cat >/dev/null; ln -s "$T/victim.txt" "\$o"; exit 0
FAKE
PATH="$T/bin:$PATH" expect_rc 73 "dispatch: staged report that is a symlink is refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/link2.md"
[[ "$(cat "$T/victim.txt")" == victim && ! -e "$REPO/.scratch/link2.md" ]] && ok "dispatch: nothing written through the link" || bad "dispatch: wrote through staged link"
cat > "$T/bin/codex" <<FAKE
#!/usr/bin/env bash
cat >/dev/null; mv "$REPO/.scratch" "$T/moved"; mkdir -p "$HOME/.claude/commands"; ln -s "$HOME/.claude/commands" "$REPO/.scratch"
o=""; while ((\$#)); do [[ "\$1" == -o ]] && o="\$2"; shift; done; echo evil > "\$o"; exit 0
FAKE
PATH="$T/bin:$PATH" expect_rc 73 "dispatch: .scratch swapped for a symlink during the run is refused" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/swap.md"
[[ ! -e "$HOME/.claude/commands/swap.md" ]] && ok "dispatch: nothing written into ~/.claude" || bad "dispatch: wrote into ~/.claude"
rm "$REPO/.scratch"; mv "$T/moved" "$REPO/.scratch"
DRY_RUN=1 bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/st.md" >"$T/out" 2>&1
grep -q "$REALHOME/.local/state/codex-dispatch/" "$T/out" && ok "dispatch: staging is in the real home, outside /tmp and TMPDIR" || bad "dispatch: staging location"
cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
cat >/dev/null; exit 0
FAKE
PATH="$T/bin:$PATH" expect_rc 74 "dispatch: -o given but Codex wrote no report -> non-zero" bash "$D" -f "$T/task.md" -s read-only -C "$REPO" -o "$REPO/.scratch/none.md"

# ---------- stop-verify ----------
H="$ROOT/hooks/stop-verify.sh"
P="$T/proj"; mkdir -p "$P/src"; git -C "$P" init -q; git -C "$P" remote add origin https://example.com/acme/my-web-app.git
echo a > "$P/src/a.ts"; echo r > "$P/README.md"; git -C "$P" add -A; git -C "$P" -c user.email=t@t -c user.name=t commit -qm init
input() { printf '{"cwd":"%s","session_id":"%s"}' "$P" "${1:-s1}"; }
PR="$(cd "$P" && pwd -P)"
conf() { printf '{"acme/my-web-app":{"roots":["%s"],"code_re":"^src/.*\\\\.ts$","verify":"%s","limit":%s}}' "$PR" "$1" "${2:-120}" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"; }
run_hook() { input "$@" | bash "$H"; }

expect_rc 0 "hook: no config file -> silent pass"   run_hook
[[ ! -s "$T/out" ]] && ok "hook: no output without config" || bad "hook: printed output without config"
conf "exit 1"
expect_rc 0 "hook: clean tree -> nothing to check"  run_hook
echo b >> "$P/README.md"
expect_rc 0 "hook: non-code change ignored"         run_hook
echo b >> "$P/src/a.ts"
conf "true";   expect_rc 0 "hook: passing checks -> exit 0"   run_hook
conf "exit 1"; expect_rc 2 "hook: failing checks -> exit 2"   run_hook
conf "exit 1"; expect_rc 2 "hook: block 1"                    run_hook s2
               expect_rc 2 "hook: block 2"                    run_hook s2
               expect_rc 2 "hook: block 3"                    run_hook s2
               expect_rc 0 "hook: 4th try still runs checks, then gives up red" run_hook s2
grep -q 'still fails' "$T/out" && ok "hook: says checks are red" || bad "hook: red message"
               expect_rc 0 "hook: same red state not re-blocked" run_hook s3
grep -q 'still RED' "$T/out" && ok "hook: a new session is told the state is still red" || bad "hook: silent red cache"
conf "sleep 5" 1; expect_rc 2 "hook: hitting the limit counts as a failure" run_hook
grep -q 'limit' "$T/out" && ok "hook: says it hit the limit" || bad "hook: timeout message"
conf "true" "\"abc\""; expect_rc 0 "hook: non-numeric limit is rejected, not run" run_hook
grep -q 'limit must be' "$T/out" && ok "hook: says the limit is invalid" || bad "hook: limit message"
C2="$T/clone2"; git clone -q "$P" "$C2"; git -C "$C2" remote set-url origin https://example.com/acme/my-web-app.git; echo z >> "$C2/src/a.ts"
conf "exit 1"
printf '{"cwd":"%s","session_id":"c2"}' "$C2" | bash "$H" >"$T/out" 2>&1; [[ $? == 0 ]] && ok "hook: same owner/repo at an untrusted path -> not run" || bad "hook: ran an untrusted checkout"
grep -q 'not in roots' "$T/out" && jq -e .systemMessage "$T/out" >/dev/null && ok "hook: says a checkout is missing from roots (valid JSON)" || bad "hook: roots miss is silent"
WT="$T/wt"; git -C "$P" worktree add -q "$WT" 2>/dev/null; echo w >> "$WT/src/a.ts"
printf '{"cwd":"%s","session_id":"wt"}' "$WT" | bash "$H" >"$T/out" 2>&1; [[ $? == 2 ]] && ok "hook: linked worktree of a trusted checkout is checked" || bad "hook: worktree skipped"
git -C "$P" worktree remove --force "$WT"
printf '{"acme/my-web-app":{"roots":["%s"],"code_re":"^src/","verify":"true","requires":"no\\\"pe"}}' "$PR" > "$HOME/.claude/stop-verify.projects.json"
run_hook >"$T/out" 2>&1; jq -e .systemMessage "$T/out" >/dev/null && ok "hook: messages stay valid JSON with quotes in config" || bad "hook: invalid JSON message"
conf "kill -9 \$\$"; expect_rc 2 "hook: signal death is a failure" run_hook
A="$T/attacker"; mkdir -p "$A/src"; git -C "$A" init -q; git -C "$A" remote add origin git@example.com:attacker/my-web-app.git
echo x > "$A/src/a.ts"; AR="$(cd "$A" && pwd -P)"
printf '{"acme/my-web-app":{"roots":["%s","%s"],"code_re":"^src/.*\\\\.ts$","verify":"exit 1","limit":120}}' "$PR" "$AR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
printf '{"cwd":"%s","session_id":"a"}' "$A" | bash "$H" >"$T/out" 2>&1; [[ $? == 0 ]] && ok "hook: same repo name, other owner -> not run" || bad "hook: matched another owner's repo"
echo c > "$P/src/b c.ts"
conf 'n=$(printf \"%s\\n\" \"$VERIFY_CHANGED\" | grep -c .); [ $n -eq 2 ] && printf \"%s\" \"$VERIFY_CHANGED\" | grep -qx \"src/b c.ts\"'
expect_rc 0 "hook: VERIFY_CHANGED is one file per line" run_hook
# test guard
G="$T/guard"; mkdir -p "$G/src" "$G/tests"; git -C "$G" init -q; git -C "$G" remote add origin https://example.com/acme/guarded.git
echo a > "$G/src/a.ts"; echo t > "$G/tests/a.test.ts"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm init
GR="$(cd "$G" && pwd -P)"
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^(src|tests)/.*\\\\.ts$","tests_re":"^tests/","verify":"true","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
ginput() { printf '{"cwd":"%s","session_id":"%s"}' "$G" "$1" | bash "$H"; }
echo b >> "$G/src/a.ts"; echo weaker > "$G/tests/a.test.ts"
expect_rc 2 "guard: fix + edited existing test -> blocked" ginput g1
grep -q 'test guard' "$T/out" && ok "guard: says why" || bad "guard: message"
git -C "$G" checkout -q tests/a.test.ts; echo n > "$G/tests/new.test.ts"
expect_rc 0 "guard: fix + NEW test file -> allowed" ginput g2
rm "$G/tests/new.test.ts"; git -C "$G" checkout -q src/a.ts; echo weaker > "$G/tests/a.test.ts"; echo new > "$G/src/added.ts"
expect_rc 2 "guard: NEW code file + edited existing test -> blocked" ginput g4
rm "$G/src/added.ts"
expect_rc 0 "guard: test-only change -> allowed" ginput g3
mkdir -p "$G/src/gen"; for i in $(seq 1 1500); do echo x > "$G/src/gen/file-with-a-long-name-$i.ts"; done
expect_rc 2 "guard: still blocks with 1500 new code files (no SIGPIPE skip)" ginput g5
rm -r "$G/src/gen"
git -C "$G" checkout -q tests/a.test.ts
# guard runs before the pass cache, even when code_re does not cover tests
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","tests_re":"^tests/","verify":"true","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
echo b2 >> "$G/src/a.ts"; expect_rc 0 "guard: code change passes first" ginput g6
echo weaker > "$G/tests/a.test.ts"; expect_rc 2 "guard: weakening a test after a pass is still blocked" ginput g6
git -C "$G" checkout -q tests/a.test.ts
git -C "$G" update-index --skip-worktree tests/a.test.ts; echo weaker > "$G/tests/a.test.ts"
expect_rc 2 "guard: test hidden with skip-worktree is still blocked" ginput g7
git -C "$G" update-index --no-skip-worktree tests/a.test.ts; git -C "$G" checkout -q tests/a.test.ts src/a.ts
# file names with quotes are fingerprinted
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","verify":"! grep -rq bad src","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
echo ok > "$G/src/q\"x.ts"; expect_rc 0 "hook: file with a quote in its name passes" ginput q1
echo bad > "$G/src/q\"x.ts"; expect_rc 2 "hook: breaking that file is caught (no stale pass)" ginput q1
rm "$G/src/q\"x.ts"
# a very long change list goes through VERIFY_CHANGED_FILE
printf '{"acme/guarded":{"roots":["%s"],"code_re":"^src/","verify":"test -s \\"$VERIFY_CHANGED_FILE\\" && test -z \\"$VERIFY_CHANGED\\" && [ $(wc -l < \\"$VERIFY_CHANGED_FILE\\") -ge 3000 ]","limit":120}}' "$GR" > "$HOME/.claude/stop-verify.projects.json"; rm -rf "$HOME/.claude/state"
mkdir -p "$G/src/many"; for i in $(seq 1 3000); do : > "$G/src/many/a-rather-long-generated-file-name-number-$i.ts"; done
expect_rc 0 "hook: 3000 changed files go through VERIFY_CHANGED_FILE (no E2BIG)" ginput big
rm -r "$G/src/many"

# evidence
E="$ROOT/tools/verify-evidence.sh"
in_g() { (cd "$G" && bash "$E" "$@"); }
echo dirty >> "$G/src/a.ts"
expect_rc 64 "evidence: dirty tree refused" in_g -- true
git -C "$G" checkout -q src/a.ts
printf '.scratch/\n' > "$G/.gitignore"; git -C "$G" add .gitignore; git -C "$G" -c user.email=t@t -c user.name=t commit -qm ignore
expect_rc 0 "evidence: passing command" in_g -- true
LOGF="$HOME/.local/state/verify-evidence/$(sed -n 's/^- Full log: kept on this machine as `\([^`]*\)` (sha256 `[0-9a-f]*`)$/\1/p' "$T/out")"; HSH="$(sed -n 's/^- Full log: .*(sha256 `\([0-9a-f]*\)`)$/\1/p' "$T/out")"
grep -q "$HOME" "$T/out" && bad "evidence: prints a local path" || ok "evidence: prints no local path"
grep -q 'Last' "$T/out" && bad "evidence: prints log text by default" || ok "evidence: no log text unless --tail"
grep -q "$(git -C "$G" rev-parse HEAD)" "$T/out" && [[ -f "$LOGF" && "$(shasum -a 256 "$LOGF" | cut -d' ' -f1)" == "$HSH" ]] && ok "evidence: names the commit; log hash matches the file" || bad "evidence: commit or hash"
[[ -z "$(git -C "$G" status --porcelain)" ]] && ok "evidence: log is written outside the work tree" || bad "evidence: dirtied the tree"
expect_rc 90 "evidence: tree changed during run -> exit 90 INVALID" in_g -- touch src/during.ts
grep -q INVALID "$T/out" && ok "evidence: says INVALID" || bad "evidence: INVALID label"
rm -f "$G/src/during.ts"
expect_rc 0 "evidence: one quoted string runs as a shell command" in_g -- 'true && echo compound-ok'
grep -q compound-ok "$T/out" && ok "evidence: compound command ran fully" || bad "evidence: compound"
grep -qF 'true && echo compound-ok`' "$T/out" && ok "evidence: shows the command as typed" || bad "evidence: command display"
expect_rc 64 "evidence: --log-dir inside the tree refused" in_g --log-dir .scratch-logs -- true
echo t2 > "$G/tests/b.test.ts"; git -C "$G" add -A; git -C "$G" -c user.email=t@t -c user.name=t commit -qm "add test"
echo weaker > "$G/tests/b.test.ts"; git -C "$G" -c user.email=t@t -c user.name=t commit -qam "weaken test"
expect_rc 0 "evidence: run with base" in_g --tests-re '^tests/' --base "$(git -C "$G" rev-list --max-parents=0 HEAD)" -- true
grep -q 'tests/b.test.ts' "$T/out" && ok "evidence: add-then-weaken inside the branch is reported" || bad "evidence: missed weakened test"
expect_rc 90 "evidence: bad base -> INVALID" in_g --tests-re '^tests/' --base no-such-ref -- true
grep -q UNKNOWN "$T/out" && ok "evidence: bad base reports UNKNOWN" || bad "evidence: bad base"
expect_rc 90 "evidence: base that already contains HEAD -> UNKNOWN, INVALID" in_g --tests-re '^tests/' --base HEAD -- true
grep -q 'already contains HEAD' "$T/out" && ok "evidence: says the base is wrong" || bad "evidence: base==HEAD"
expect_rc 0 "evidence: --tail shows the log end" in_g --tail 5 -- echo tail-line
grep -q tail-line "$T/out" && ok "evidence: tail printed on request" || bad "evidence: --tail"
git -C "$G" update-index --skip-worktree "$(git -C "$G" ls-files tests | head -1)"
expect_rc 64 "evidence: skip-worktree files refused" in_g -- true
git -C "$G" update-index --no-skip-worktree "$(git -C "$G" ls-files tests | head -1)"
expect_rc 1 "evidence: failing command keeps exit code" in_g -- false
grep -q FAIL "$T/out" && ok "evidence: says FAIL" || bad "evidence: FAIL label"

printf 'not json' > "$HOME/.claude/stop-verify.projects.json"
expect_rc 0 "hook: broken config never traps the session" run_hook

echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
