#!/usr/bin/env bash
# post-edit-check.sh — layer 1 (PostToolUse, matcher Edit|Write|MultiEdit).
#
# After Claude edits a file in a registered, trusted checkout, run the project's quick check
# (for example tsc or a linter) and look only at what it says about THAT file.
#   exit 2   the check exits non-zero AND some output line names the edited file.
#            The edit has already happened; this hook cannot undo it. stderr goes to Claude.
#   exit 0   everything else: no config, no edit_check, file does not match files_re, untrusted
#            checkout, check passed, errors only in other files, time limit, missing tool,
#            vanished file, the hook's own error. Problems are written to the ledger as
#            timeout / error and shown as a systemMessage; they never block.
#
# Config: the same projects file as stop-verify.sh (~/.claude/stop-verify.projects.json, or
# $STOP_VERIFY_CONFIG), same "roots" trust. Optional field per project:
#   "edit_check": { "files_re": "<ERE on the repo-relative path>",
#                   "cmd":      "<bash, run at the repo root; $EDIT_FILE = repo-relative path>",
#                   "limit":    20 }          # seconds, 1..22, default 20
# No edit_check -> this hook does nothing for that project.
#
# The path match is by whole path components (repo-relative or absolute): src/a.ts is not
# lib/src/a.ts and not src/a.tsx. At most 20 diagnostic lines are shown.
#
# Whole decision runs under a watchdog (25 s; the plugin hook timeout is 30). The inner process
# is started by us with --inner; an inherited variable cannot skip the watchdog.
# Test-only overrides POST_EDIT_STATE and POST_EDIT_LIMIT are ignored when this script lives
# under ~/.claude (an installed copy or plugin). They never touch trust: trust is only "roots".
# Ledger: ~/.claude/state/post-edit-check/ledger.tsv  (time, project, file, result, seconds)
#   result: pass | block | timeout | skip | error
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd -P)"
CONF="${STOP_VERIFY_CONFIG:-$HOME/.claude/stop-verify.projects.json}"
[[ -f "$CONF" ]] || exit 0
STATE_DIR="$HOME/.claude/state/post-edit-check"
TOTAL_LIMIT=25
CLAUDE_HOME="$(cd "$HOME/.claude" 2>/dev/null && pwd -P)"
if [[ -z "$CLAUDE_HOME" || "$SELF_DIR" != "$CLAUDE_HOME"/* ]]; then
  STATE_DIR="${POST_EDIT_STATE:-$STATE_DIR}"
  [[ "${POST_EDIT_LIMIT:-}" =~ ^[0-9]{1,3}$ ]] && TOTAL_LIMIT=$((10#$POST_EDIT_LIMIT)) && (( TOTAL_LIMIT >= 1 )) || TOTAL_LIMIT=25
fi
INNER=0; for a in "$@"; do [[ "$a" == --inner ]] && INNER=1; done
# shellcheck source=lib/projects.sh
source "$SELF_DIR/lib/projects.sh" 2>/dev/null || exit 0

led() {  # project, file, result, seconds
  ( umask 077; mkdir -p "$STATE_DIR" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$(clean_tabs "$1")" "$(clean_tabs "$2")" "$3" "$4" >> "$STATE_DIR/ledger.tsv" ) 2>/dev/null
}
note() { jq -cn --arg m "[post-edit-check] $1" '{systemMessage:$m}' 2>/dev/null; }

# ---------- outer: watchdog around the whole decision ----------
if (( INNER == 0 )); then
  command -v jq >/dev/null 2>&1 || exit 0
  command -v perl >/dev/null 2>&1 || exit 0
  INPUT="$(cat)"
  OUTF="$(mktemp "${TMPDIR:-/tmp}/pec-out.XXXXXX")" || exit 0
  ERRF="$(mktemp "${TMPDIR:-/tmp}/pec-err.XXXXXX")" || { /bin/rm -f "$OUTF"; exit 0; }
  trap '/bin/rm -f "$OUTF" "$ERRF"' EXIT
  T0=$SECONDS
  printf '%s' "$INPUT" | run_limited "$TOTAL_LIMIT" bash "$SELF" --inner >"$OUTF" 2>"$ERRF"; RC=$?
  if (( RC == 124 || (RC != 0 && RC != 2) )); then
    F="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    if (( RC == 124 )); then led "-" "$F" timeout "$((SECONDS - T0))"; note "Edit check timed out (${TOTAL_LIMIT} s); not verified."
    else led "-" "$F" error "$((SECONDS - T0))"; note "Edit check failed by itself (rc=${RC}); not verified."; fi
    exit 0
  fi
  cat "$OUTF"; cat "$ERRF" >&2
  exit "$RC"
fi

# ---------- inner ----------
START=$SECONDS
INPUT="$(cat)"
j() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null; }
case "$(j '.tool_name // empty')" in ""|Edit|Write|MultiEdit) ;; *) exit 0 ;; esac
FILE="$(j '.tool_input.file_path // empty')"
[[ -n "$FILE" ]] || exit 0
if [[ "$FILE" != /* ]]; then C="$(j '.cwd // empty')"; [[ -n "$C" ]] && FILE="$C/$FILE" || exit 0; fi
KEY="-"; REL="$FILE"
L() { led "$KEY" "$REL" "$1" "$((SECONDS - START))"; }
soft() {  # result, message: log + exit 0 with a visible "not verified" notice
  L "$1"; note "$2 ($REL); not verified."; exit 0
}

[[ -f "$FILE" ]] || exit 0
[[ -L "$FILE" ]] && { L skip; exit 0; }   # a link could point out of the checkout
DIR="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P)" || exit 0
resolve_trusted "$DIR" || { [[ "$R_WHY" == untrusted ]] && { KEY="$R_KEY"; L skip; }; exit 0; }
KEY="$R_KEY"; ROOT="$R_ROOT"
EC="$(jq -c --arg k "$KEY" '.[$k].edit_check // empty' "$CONF" 2>/dev/null)"
[[ -n "$EC" ]] || exit 0
REL="${DIR#"$ROOT"}/${FILE##*/}"; REL="${REL#/}"
ABS="$DIR/${FILE##*/}"

if ! printf '%s' "$EC" | jq -e 'type == "object" and (.files_re | type) == "string" and (.cmd | type) == "string" and ((has("limit") | not) or (.limit | type) == "number")' >/dev/null 2>&1; then
  soft error "edit_check in the projects file needs files_re and cmd (strings) and an optional numeric limit"
fi
FILES_RE="$(printf '%s' "$EC" | jq -r '.files_re')"; CMD="$(printf '%s' "$EC" | jq -r '.cmd')"
LIMIT="$(printf '%s' "$EC" | jq -r '.limit // 20 | floor')"
[[ -n "$FILES_RE" && -n "$CMD" ]] || soft error "edit_check files_re and cmd must not be empty"
re_ok "$FILES_RE" || soft error "edit_check files_re is not a valid regex"
[[ "$REL" =~ $FILES_RE ]] || exit 0
BUDGET=$((TOTAL_LIMIT - 3)); (( BUDGET >= 1 )) || BUDGET=1
[[ "$LIMIT" =~ ^[0-9]+$ ]] && (( LIMIT >= 1 && LIMIT <= BUDGET )) || LIMIT=$BUDGET

OUT="$(mktemp "${TMPDIR:-/tmp}/post-edit-check.XXXXXX")" || exit 0
trap '/bin/rm -f "$OUT"' EXIT
export NPM_CONFIG_UPDATE_NOTIFIER=false
( cd "$ROOT" && EDIT_FILE="$REL" run_limited "$LIMIT" bash -c "$CMD" ) </dev/null >"$OUT" 2>&1; RC=$?
[[ -f "$FILE" ]] || soft error "The file disappeared during the check"
(( RC == 0 )) && { L pass; exit 0; }
(( RC == 124 )) && soft timeout "The check timed out after ${LIMIT} s"
(( RC == 126 || RC == 127 || RC > 128 )) && soft error "The check could not run or was killed (rc=${RC})"

# Non-zero exit: block only if a line names THIS file, as whole path components.
HITS="$(perl -e '
  my ($rel, $abs) = @ARGV;
  while (my $l = <STDIN>) {
    chomp $l;
    for my $n ($abs, $rel) {
      next if $n eq "";
      if ($l =~ /(?<![\w.\/@~-])(?:\.\/)?\Q$n\E(?![\w\/-]|\.\w)/) { print "$l\n"; last }
    }
  }' "$REL" "$ABS" < "$OUT" 2>/dev/null)"
if [[ -z "$HITS" ]]; then L pass; exit 0; fi
L block
NH="$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')"
{
  echo "[post-edit-check] $REL: the check failed (exit $RC) and reports this file. The edit is already saved; fix it before you continue."
  printf '%s\n' "$HITS" | head -20 | LC_ALL=C cut -c1-300
  (( NH > 20 )) && echo "($((NH - 20)) more lines not shown)"
} >&2
exit 2
