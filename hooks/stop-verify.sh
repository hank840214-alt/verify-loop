#!/usr/bin/env bash
# stop-verify.sh — one Stop hook for every registered project (verify-loop).
#
# When Claude tries to finish a turn inside a registered repo whose code differs
# from HEAD or from origin/main, run that project's verify command.
#   pass                 -> exit 0, Claude stops.
#   fail or time limit   -> summary on stderr + exit 2, Claude must fix it.
#   hook's own problem   -> exit 0 with a systemMessage (never traps the session).
#
# Projects live in ~/.claude/stop-verify.projects.json (or $STOP_VERIFY_CONFIG),
# keyed by "owner/repo" from the origin remote. No config file -> the hook does nothing.
# Fields:
#   code_re    files that trigger a run (extended regex, repo-relative)
#   verify     bash command run at the repo root. $VERIFY_CHANGED_FILE names a file with the
#              changed files, one per line; $VERIFY_CHANGED holds the same list when it is small.
#   requires   path that must exist first (e.g. node_modules), optional
#   limit      seconds before the run counts as failed (default 480)
#   roots      REQUIRED: absolute paths of the checkouts you trust, e.g. ["/home/me/src/shop"].
#              Another clone with the same owner/repo is never run. Linked worktrees of a
#              trusted checkout are trusted. Trust is by path: whatever branch is checked
#              out there is run with your permissions.
#   tests_re   optional: existing files matching it may not be modified or deleted in the
#              same change as other code (the fixer may not grade itself)
#
# One deadline for the whole hook (DEADLINE s, below the 600 s hook timeout), so
# the hook can never run past its timeout and fail open.
#
# Order: test guard first, then the fingerprint cache (same changes already passed -> skip);
# at most MAX_BLOCKS blocks in a row per session, then Claude may stop.

set -uo pipefail
MAX_BLOCKS=3
DEADLINE=540
CONF="${STOP_VERIFY_CONFIG:-$HOME/.claude/stop-verify.projects.json}"
STATE_DIR="$HOME/.claude/state/stop-verify"
SMALL_LIST=32000   # bytes; bigger change lists go only through VERIFY_CHANGED_FILE

[[ -f "$CONF" ]] || exit 0
command -v jq >/dev/null 2>&1 || { printf '{"systemMessage":"[stop-verify] jq missing; verification skipped"}\n'; exit 0; }
msg() { jq -cn --arg m "[stop-verify] $1" '{systemMessage:$m}'; }
note() { msg "$1"; exit 0; }
command -v perl >/dev/null 2>&1 || note "perl missing; verification skipped"
if command -v shasum >/dev/null 2>&1; then HASH=shasum
elif command -v sha1sum >/dev/null 2>&1; then HASH=sha1sum
else note "shasum/sha1sum missing; verification skipped"; fi
hsum() { "$HASH" -- "$@"; }
jq -e . "$CONF" >/dev/null 2>&1 || note "projects.json is not valid JSON; verification skipped"

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')"
SESSION="${SESSION//[^A-Za-z0-9_-]/_}"
[[ -n "$CWD" && -d "$CWD" ]] || exit 0

export NPM_CONFIG_UPDATE_NOTIFIER=false

project_of() {  # repo root -> project key, or empty
  local url name
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  name="${url%/}"; name="${name%.git}"; name="${name%/}"; name="${name##*:}"   # git@host:owner/repo -> owner/repo
  name="$(printf '%s' "$name" | awk -F/ 'NF>=2{print $(NF-1)"/"$NF}')"
  [[ -n "$name" ]] || return 0
  jq -e --arg k "$name" 'has($k)' "$CONF" >/dev/null 2>&1 && printf '%s' "$name"
}
field() { jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONF"; }

run_limited() {  # seconds, command...  -> exit 124 on time limit, kills the whole group
  perl -e '
    my $t = shift; $t = 1 if $t < 1; my $pid = fork();
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 3; kill "KILL", -$pid; exit 124 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}

re_ok() { [[ -z "$1" ]] && return 0; [[ "" =~ $1 ]]; [[ $? -le 1 ]]; }

# NUL-separated, so tabs, quotes and newlines in file names are never mangled.
# --no-renames: a moved file shows its old path too, so moving code out of code_re still counts.
uncommitted_z() { git diff -z --no-renames --name-only HEAD && git ls-files -z --others --exclude-standard; }

verify_root() {
  local ROOT="$1" KEY="$2"
  cd "$ROOT" || return 0
  local CODE_RE VERIFY REQ LIMIT TESTS_RE
  CODE_RE="$(field "$KEY" code_re)"; VERIFY="$(field "$KEY" verify)"; TESTS_RE="$(field "$KEY" tests_re)"
  REQ="$(field "$KEY" requires)"; LIMIT="$(field "$KEY" limit)"; LIMIT="${LIMIT:-480}"
  [[ -n "$CODE_RE" && -n "$VERIFY" ]] || return 0
  [[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 && LIMIT <= DEADLINE )) || { msg "$KEY: limit must be 1-$DEADLINE seconds; checks skipped"; return 0; }
  re_ok "$CODE_RE" && re_ok "$TESTS_RE" || { msg "$KEY: invalid regex in config; checks skipped"; return 0; }
  if [[ -n "$REQ" && ! -e "$ROOT/$REQ" ]]; then msg "$KEY: $REQ is missing, checks skipped"; return 0; fi
  local BASE
  BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/main >/dev/null && BASE=origin/main; }
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/master >/dev/null && BASE=origin/master; }

  local f CODE=() TESTF=() UNC_CODE=0 LZ
  LZ="$(mktemp "${TMPDIR:-/tmp}/stop-verify-z.XXXXXX")" || note "mktemp failed; verification skipped"
  if ! { uncommitted_z && { [[ -z "$BASE" ]] || git diff -z --no-renames --name-only "$BASE"...HEAD; }; } >"$LZ" 2>/dev/null; then
    rm -f "$LZ"; msg "$KEY: git could not list the changed files; checks NOT run"; return 0
  fi
  while IFS= read -r -d '' f; do
    [[ "$f" =~ $CODE_RE ]] && CODE+=("$f")
    [[ -n "$TESTS_RE" && "$f" =~ $TESTS_RE ]] && TESTF+=("$f")
  done < <(sort -zu "$LZ")
  rm -f "$LZ"
  if (( ${#CODE[@]} == 0 )); then
    [[ "${STOP_VERIFY_DRY:-0}" == 1 ]] && echo "[dry] $KEY: no changed files match code_re (base: ${BASE:-none})" >&2
    return 0
  fi

  mkdir -p "$STATE_DIR" || return 0
  local ID COUNT_FILE PASS_FILE RED_FILE BLOCKS
  ID="$(printf '%s' "$ROOT" | hsum | cut -c1-16)"
  PASS_FILE="$STATE_DIR/$ID.pass"; RED_FILE="$STATE_DIR/$ID.red"; COUNT_FILE="$STATE_DIR/$ID.$SESSION.blocks"
  BLOCKS="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"; [[ "$BLOCKS" =~ ^[0-9]+$ ]] || BLOCKS=0

  # Test guard (before any cache): the change that fixes code may not also edit the
  # existing tests that judge it. Uncommitted edits only; committed test edits are
  # listed by verify-evidence.sh for the PR reviewer.
  if [[ -n "$TESTS_RE" ]]; then
    local st old TAMPER=() e tag NS
    NS="$(mktemp "${TMPDIR:-/tmp}/stop-verify-ns.XXXXXX")" || note "mktemp failed; verification skipped"
    if ! git diff -z --no-renames --name-status HEAD >"$NS" 2>/dev/null || ! uncommitted_z >/dev/null 2>&1; then
      rm -f "$NS"; msg "$KEY: git could not list edited tests; checks NOT run"; return 0
    fi
    while IFS= read -r -d '' st; do
      case "$st" in
        R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' f; f="$old" ;;
        *) IFS= read -r -d '' f ;;
      esac
      case "$st" in M*|D*|R*|T*) [[ "$f" =~ $TESTS_RE ]] && TAMPER+=("$f") ;; esac
    done < "$NS"
    rm -f "$NS"
    # Files hidden from git status (skip-worktree / assume-unchanged) count as edited.
    while IFS= read -r -d '' e; do
      tag="${e%% *}"; f="${e#* }"
      [[ "$tag" == S || "$tag" =~ ^[a-z]$ ]] && [[ "$f" =~ $TESTS_RE ]] && TAMPER+=("$f (hidden from git status)")
    done < <(git ls-files -z -v 2>/dev/null)
    while IFS= read -r -d '' f; do
      [[ "$f" =~ $CODE_RE && ! "$f" =~ $TESTS_RE ]] && { UNC_CODE=1; break; }
    done < <(uncommitted_z 2>/dev/null)
    if (( ${#TAMPER[@]} > 0 && UNC_CODE )); then
      if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then echo "[dry] $KEY: test guard would block: ${TAMPER[*]}" >&2; return 0; fi
      if (( BLOCKS >= MAX_BLOCKS )); then
        rm -f "$COUNT_FILE"; msg "$KEY: test guard still fails after $MAX_BLOCKS blocked stops. Claude stopped anyway; existing tests were edited together with code."; return 0
      fi
      echo $((BLOCKS + 1)) > "$COUNT_FILE"
      {
        echo "[stop-verify] $KEY: test guard (try $((BLOCKS + 1))/$MAX_BLOCKS). This change edits code AND existing tests that judge it:"
        printf '  %s\n' "${TAMPER[@]}"
        echo "The agent that writes a fix may not change the tests it is graded by. Revert the edits to those tests."
        echo "If a test is really wrong, stop and say so: the test change goes in its own change, written or approved by someone else (a different agent or the user)."
        echo "New test files are fine."
      } >&2
      return 2
    fi
  fi

  # Fingerprint: HEAD, the verify command, and the content of every changed code or test file.
  local FPRINT HLEFT
  HLEFT=$((DEADLINE - SECONDS - 60))
  FPRINT="$( { git rev-parse HEAD 2>/dev/null; printf '%s\n' "$VERIFY";
    for f in ${CODE[@]+"${CODE[@]}"} ${TESTF[@]+"${TESTF[@]}"}; do [[ -f "$f" ]] || printf 'deleted %s\0' "$f"; done
    for f in ${CODE[@]+"${CODE[@]}"} ${TESTF[@]+"${TESTF[@]}"}; do [[ -f "$f" ]] && printf '%s\0' "$f"; done \
      | run_limited "$HLEFT" xargs -0 "$HASH" -- 2>/dev/null || echo "hash-incomplete $RANDOM$RANDOM";
  } | hsum | cut -c1-40)"
  [[ ${#FPRINT} == 40 ]] || { msg "could not fingerprint changes; checks skipped"; return 0; }
  [[ -f "$PASS_FILE" && "$(cat "$PASS_FILE")" == "$FPRINT" ]] && return 0
  [[ -f "$RED_FILE" && "$(cat "$RED_FILE")" == "$FPRINT" ]] && { msg "$KEY: checks are still RED for this exact state (an earlier stop gave up). Fix it or tell the user."; return 0; }

  if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then
    echo "[dry] $KEY in $ROOT limit=${LIMIT}s changed=${#CODE[@]} :: $VERIFY" >&2
    return 0
  fi

  local LOG LIST RC START SECS LEFT
  LOG="$(mktemp "${TMPDIR:-/tmp}/stop-verify.XXXXXX")" || note "mktemp failed; verification skipped"
  LIST="$(mktemp "${TMPDIR:-/tmp}/stop-verify-list.XXXXXX")" || note "mktemp failed; verification skipped"
  printf '%s\n' "${CODE[@]}" > "$LIST"
  local SMALL=""; (( $(wc -c < "$LIST") <= SMALL_LIST )) && SMALL="$(cat "$LIST")"
  LEFT=$((DEADLINE - SECONDS)); (( LEFT < LIMIT )) && LIMIT=$LEFT
  START=$SECONDS
  if (( LEFT < 60 )); then
    RC=124; echo "not enough time left in this stop to run checks" >"$LOG"
  else
    VERIFY_CHANGED="$SMALL" VERIFY_CHANGED_FILE="$LIST" run_limited "$LIMIT" bash -c "$VERIFY" >"$LOG" 2>&1
    RC=$?
  fi
  SECS=$((SECONDS - START)); rm -f "$LIST"
  if (( RC == 0 )); then
    printf '%s' "$FPRINT" > "$PASS_FILE"; rm -f "$COUNT_FILE" "$LOG" "$RED_FILE"; return 0
  fi

  if (( BLOCKS >= MAX_BLOCKS )); then
    rm -f "$LOG" "$COUNT_FILE"; printf '%s' "$FPRINT" > "$RED_FILE"
    msg "$KEY still fails after $MAX_BLOCKS blocked stops (rc=$RC). Claude stopped anyway; checks are RED. This exact state will not be re-checked."
    return 0
  fi
  echo $((BLOCKS + 1)) > "$COUNT_FILE"
  {
    if (( RC == 124 )); then
      echo "[stop-verify] $KEY: checks hit the ${LIMIT}s limit in $ROOT (try $((BLOCKS + 1))/$MAX_BLOCKS). A timeout counts as a failure."
    else
      echo "[stop-verify] $KEY: checks failed (rc=$RC, ${SECS}s) in $ROOT (try $((BLOCKS + 1))/$MAX_BLOCKS)."
    fi
    echo "If these failures come from this session's changes, fix the cause and finish again."
    echo "If they do not (the user's own work in progress), say so and stop; do not edit their work. Output:"
    if grep -q "failing tests:" "$LOG"; then sed -n '/failing tests:/,$p' "$LOG" | head -80; else tail -60 "$LOG"; fi
  } >&2
  rm -f "$LOG"
  return 2
}

ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
KEY="$(project_of "$ROOT")"
[[ -n "$KEY" ]] || exit 0
# Only checkouts listed in "roots" (and their linked worktrees) are trusted.
in_roots() { [[ -n "$1" ]] && jq -e --arg k "$KEY" --arg r "$1" '(.[$k].roots // []) | map(sub("/+$";"")) | index($r) != null' "$CONF" >/dev/null 2>&1; }
RROOT="$(cd "$ROOT" && pwd -P)"
COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
MAIN="$( [[ -n "$COMMON" ]] && cd "$COMMON/.." 2>/dev/null && pwd -P)"
# A worktree counts only if the trusted checkout itself lists it (a crafted .git file is not enough).
trusted_worktree() {
  [[ -n "$MAIN" && "$MAIN" != "$RROOT" ]] && in_roots "$MAIN" || return 1
  local line p
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    p="$(cd "${line#worktree }" 2>/dev/null && pwd -P)" && [[ "$p" == "$RROOT" ]] && return 0
  done < <(git -C "$MAIN" worktree list --porcelain 2>/dev/null)
  return 1
}
if ! in_roots "$RROOT" && ! trusted_worktree; then
  if jq -e --arg k "$KEY" '.[$k].roots' "$CONF" >/dev/null 2>&1; then
    msg "$KEY: this checkout is not in roots, so its checks are not run. To trust it, add its real path to roots: $RROOT"
  else
    msg "$KEY has no roots list; add this checkout path to roots to trust it: $RROOT"
  fi
  exit 0
fi
verify_root "$ROOT" "$KEY"
exit $?
