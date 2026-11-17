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
#   verify     bash command run at the repo root; $VERIFY_CHANGED holds the changed files, one per line
#   requires   path that must exist first (e.g. node_modules), optional
#   limit      seconds before the run counts as failed (default 480)
#   roots      REQUIRED: absolute paths of the checkouts you trust, e.g. ["/home/me/src/shop"].
#              Another clone with the same owner/repo is never run.
#   tests_re   optional: existing files matching it may not be modified or deleted in the
#              same change as other code (the fixer may not grade itself)
#
# One deadline for the whole hook (DEADLINE s, below the 600 s hook timeout), so
# the hook can never run past its timeout and fail open.
#
# Guards: fingerprint cache (same changes already passed -> skip);
# at most MAX_BLOCKS blocks in a row per session, then Claude may stop.

set -uo pipefail
MAX_BLOCKS=3
DEADLINE=540
CONF="${STOP_VERIFY_CONFIG:-$HOME/.claude/stop-verify.projects.json}"
STATE_DIR="$HOME/.claude/state/stop-verify"

note() { printf '{"systemMessage":"[stop-verify] %s"}\n' "$1"; exit 0; }
[[ -f "$CONF" ]] || exit 0
command -v jq >/dev/null 2>&1 || note "jq missing; verification skipped"
if command -v shasum >/dev/null 2>&1; then HASH=shasum
elif command -v sha1sum >/dev/null 2>&1; then HASH=sha1sum
else note "shasum/sha1sum missing; verification skipped"; fi
hsum() { "$HASH" -- "$@"; }
jq -e . "$CONF" >/dev/null 2>&1 || note "projects.json is not valid JSON; verification skipped"

INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"')"
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
    my $t = shift; my $pid = fork();
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 3; kill "KILL", -$pid; exit 124 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}

verify_root() {
  local ROOT="$1" KEY="$2"
  cd "$ROOT" || return 0
  local CODE_RE VERIFY REQ LIMIT
  CODE_RE="$(field "$KEY" code_re)"; VERIFY="$(field "$KEY" verify)"
  REQ="$(field "$KEY" requires)"; LIMIT="$(field "$KEY" limit)"; LIMIT="${LIMIT:-480}"
  [[ -n "$CODE_RE" && -n "$VERIFY" ]] || return 0
  [[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 && LIMIT <= 3600 )) || { printf '{"systemMessage":"[stop-verify] %s: limit must be 1-3600 seconds; checks skipped"}\n' "$KEY"; return 0; }
  local re; for re in "$CODE_RE" "$(field "$KEY" tests_re)"; do
    [[ -z "$re" ]] && continue
    printf '' | grep -E "$re" >/dev/null 2>&1; [[ $? -le 1 ]] || { printf '{"systemMessage":"[stop-verify] %s: invalid regex in config; checks skipped"}\n' "$KEY"; return 0; }
  done
  if [[ -n "$REQ" && ! -e "$ROOT/$REQ" ]]; then
    printf '{"systemMessage":"[stop-verify] %s: %s is missing, checks skipped"}\n' "$KEY" "$REQ"; return 0
  fi
  local BASE
  BASE="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/main >/dev/null && BASE=origin/main; }
  [[ -n "$BASE" ]] || { git rev-parse -q --verify origin/master >/dev/null && BASE=origin/master; }

  local CHANGED
  CHANGED="$( { git -c core.quotePath=false diff --name-only HEAD 2>/dev/null; git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null;
    [[ -n "$BASE" ]] && git -c core.quotePath=false diff --name-only "$BASE"...HEAD 2>/dev/null; } | grep -E "$CODE_RE" | sort -u )"
  if [[ -z "$CHANGED" ]]; then
    [[ "${STOP_VERIFY_DRY:-0}" == 1 ]] && echo "[dry] $KEY: no changed files match code_re (base: ${BASE:-none})" >&2
    return 0
  fi

  mkdir -p "$STATE_DIR" || return 0
  local ID PASS_FILE COUNT_FILE FPRINT BLOCKS
  ID="$(printf '%s' "$ROOT" | hsum | cut -c1-16)"
  PASS_FILE="$STATE_DIR/$ID.pass"; COUNT_FILE="$STATE_DIR/$ID.$SESSION.blocks"
  FPRINT="$( { git rev-parse HEAD 2>/dev/null; printf '%s\n' "$VERIFY";
    printf '%s\n' "$CHANGED" | while IFS= read -r f; do [[ -f "$f" ]] || printf '%s deleted\n' "$f"; done;
    printf '%s\n' "$CHANGED" | while IFS= read -r f; do [[ -f "$f" ]] && printf '%s\0' "$f"; done | xargs -0 "$HASH" -- 2>/dev/null;
  } | hsum | cut -c1-40)"
  [[ ${#FPRINT} == 40 ]] || { printf '{"systemMessage":"[stop-verify] could not fingerprint changes; checks skipped"}\n'; return 0; }
  [[ -f "$PASS_FILE" && "$(cat "$PASS_FILE")" == "$FPRINT" ]] && return 0
  [[ -f "$STATE_DIR/$ID.red" && "$(cat "$STATE_DIR/$ID.red")" == "$FPRINT" ]] && return 0

  BLOCKS="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
  # Checks always run; only after they fail again past MAX_BLOCKS may Claude stop (red).
  give_up() {
    rm -f "$COUNT_FILE"; printf '%s' "$FPRINT" > "$STATE_DIR/$ID.red"
    printf '{"systemMessage":"[stop-verify] %s still fails after %s tries (%s). Claude stopped anyway; checks are RED. This exact state will not be re-checked."}\n' "$KEY" "$MAX_BLOCKS" "$1"
    return 0
  }

  # Test guard: the change that fixes code may not also edit the existing tests that judge it.
  local TESTS_RE TAMPER
  TESTS_RE="$(field "$KEY" tests_re)"
  if [[ -n "$TESTS_RE" ]]; then
    # Uncommitted edits only: old unpushed history is not this session's fix.
    # Committed test edits are listed by verify-evidence.sh for the PR reviewer.
    TAMPER="$( git -c core.quotePath=false diff --name-status HEAD 2>/dev/null \
      | awk -F'\t' '$1 ~ /^(M|D|R|T)/ {print $2}' | grep -E -- "$TESTS_RE" | sort -u )"
    if [[ -n "$TAMPER" ]] && { git -c core.quotePath=false diff --name-only HEAD 2>/dev/null
         git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null; } \
         | grep -E -- "$CODE_RE" | grep -vqE -- "$TESTS_RE"; then
      if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then echo "[dry] $KEY: test guard would block: $(printf '%s' "$TAMPER" | tr '\n' ' ')" >&2; return 0; fi
      (( BLOCKS >= MAX_BLOCKS )) && { give_up "test guard"; return 0; }
      echo $((BLOCKS + 1)) > "$COUNT_FILE"
      {
        echo "[stop-verify] $KEY: test guard (try $((BLOCKS + 1))/$MAX_BLOCKS). This change edits code AND existing tests that judge it:"
        printf '%s\n' "$TAMPER" | sed 's/^/  /' 
        echo "The agent that writes a fix may not change the tests it is graded by. Revert the edits to those tests."
        echo "If a test is really wrong, stop and say so: the test change goes in its own change, written or approved by someone else (a different agent or the user)."
        echo "New test files are fine."
      } >&2
      return 2
    fi
  fi

  if [[ "${STOP_VERIFY_DRY:-0}" == 1 ]]; then
    echo "[dry] $KEY in $ROOT limit=${LIMIT}s changed=$(printf "%s\n" "$CHANGED" | grep -c .) :: $VERIFY" >&2
    return 0
  fi

  local LOG RC START SECS LEFT
  LOG="$(mktemp "${TMPDIR:-/tmp}/stop-verify.XXXXXX")" || note "mktemp failed; verification skipped"
  LEFT=$((DEADLINE - SECONDS)); (( LEFT < LIMIT )) && LIMIT=$LEFT
  START=$SECONDS
  if (( LEFT < 60 )); then
    RC=124; echo "not enough time left in this stop to run checks" >"$LOG"
  else
    VERIFY_CHANGED="$CHANGED" run_limited "$LIMIT" bash -c "$VERIFY" >"$LOG" 2>&1
    RC=$?
  fi
  SECS=$((SECONDS - START))
  if (( RC == 0 )); then
    printf '%s' "$FPRINT" > "$PASS_FILE"; rm -f "$COUNT_FILE" "$LOG" "$STATE_DIR/$ID.red"; return 0
  fi

  (( BLOCKS >= MAX_BLOCKS )) && { rm -f "$LOG"; give_up "rc=$RC"; return 0; }
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
# Only checkouts listed in "roots" are trusted; a same-named clone elsewhere is ignored.
RROOT="$(cd "$ROOT" && pwd -P)"
jq -e --arg k "$KEY" --arg r "$RROOT" '(.[$k].roots // []) | map(sub("/+$";"")) | index($r) != null' "$CONF" >/dev/null 2>&1 || {
  jq -e --arg k "$KEY" '.[$k].roots' "$CONF" >/dev/null 2>&1 || printf '{"systemMessage":"[stop-verify] %s has no roots list; add this checkout path to roots to trust it"}\n' "$KEY"
  exit 0; }
verify_root "$ROOT" "$KEY"
exit $?
