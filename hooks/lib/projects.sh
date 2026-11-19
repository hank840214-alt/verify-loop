# projects.sh — sourced by post-edit-check.sh and subagent-verify.sh (not a hook itself).
# Same projects file and same trust model as stop-verify.sh: a checkout counts only if its
# physical path is listed in "roots" of its project (key owner/repo from the origin remote),
# or it is a linked worktree that the listed checkout itself reports. Nothing here reads
# trust from the environment. Needs: $CONF, jq, git.

project_of() {  # repo root -> project key, or empty
  local url name
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  name="${url%/}"; name="${name%.git}"; name="${name%/}"; name="${name##*:}"   # git@host:owner/repo -> owner/repo
  name="$(printf '%s' "$name" | awk -F/ 'NF>=2{print $(NF-1)"/"$NF}')"
  [[ -n "$name" ]] || return 0
  jq -e --arg k "$name" 'has($k)' "$CONF" >/dev/null 2>&1 && printf '%s' "$name"
}
pfield() { jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$CONF"; }   # key, field
in_roots() { [[ -n "$2" ]] && jq -e --arg k "$1" --arg r "$2" '(.[$k].roots // []) | map(sub("/+$";"")) | index($r) != null' "$CONF" >/dev/null 2>&1; }   # key, physical path

# resolve_trusted DIR -> 0 and sets R_ROOT (physical repo root) and R_KEY when DIR is inside a
# trusted checkout of a registered project. Otherwise returns 1 and sets R_WHY to
# nogit | outside | unregistered | untrusted.
resolve_trusted() {
  local d="$1" dp top common main line p
  R_ROOT=""; R_KEY=""; R_WHY=nogit
  dp="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  top="$(git -C "$dp" rev-parse --show-toplevel 2>/dev/null)" || return 1
  R_ROOT="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  # The directory must really lie inside the work tree git reported. (A repo whose
  # core.worktree points at a trusted checkout elsewhere is not that checkout.)
  [[ "$dp" == "$R_ROOT" || "$dp" == "$R_ROOT"/* ]] || { R_WHY=outside; return 1; }
  R_KEY="$(project_of "$R_ROOT")"
  [[ -n "$R_KEY" ]] || { R_WHY=unregistered; return 1; }
  R_WHY=untrusted
  in_roots "$R_KEY" "$R_ROOT" && return 0
  # A worktree counts only if the trusted checkout itself lists it (a crafted .git file is not enough).
  common="$(git -C "$R_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main="$( [[ -n "$common" ]] && cd "$common/.." 2>/dev/null && pwd -P)"
  if [[ -n "$main" && "$main" != "$R_ROOT" ]] && in_roots "$R_KEY" "$main"; then
    while IFS= read -r line; do
      [[ "$line" == "worktree "* ]] || continue
      p="$(cd "${line#worktree }" 2>/dev/null && pwd -P)" && [[ "$p" == "$R_ROOT" ]] && return 0
    done < <(git -C "$main" worktree list --porcelain 2>/dev/null)
  fi
  return 1
}

re_ok() { [[ -z "$1" ]] && return 0; [[ "" =~ $1 ]]; [[ $? -le 1 ]]; }

run_limited() {  # seconds, command...  -> exit 124 on time limit, kills the whole group
  # TERM or INT sent to this wrapper (for example by an outer watchdog) is forwarded to the
  # command's group, so nothing is left running behind it.
  perl -e '
    my $t = shift; $t = 1 if $t < 1; my $pid = fork(); defined $pid or exit 127;
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    setpgrp($pid, $pid);
    my $stop = sub { my $w = shift; kill "TERM", -$pid; select(undef,undef,undef,$w); kill "KILL", -$pid; };
    $SIG{ALRM} = sub { $stop->(0.5); exit 124 };
    $SIG{TERM} = $SIG{INT} = sub { $stop->(0.2); exit 143 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}
clean_tabs() { printf '%s' "${1//[$'\t\r\n']/_}"; }

# One ledger line: ledger_append STATE_DIR field... (tab separated, mode 600). led_bounded runs it
# under a short time limit, so a stuck file system cannot hold the hook past its watchdog.
ledger_append() {
  local dir="$1"; shift
  ( umask 077; mkdir -p "$dir" && { printf '%s' "$(date -u +%FT%TZ)"; local f; for f in "$@"; do printf '\t%s' "$(clean_tabs "$f")"; done; printf '\n'; } >> "$dir/ledger.tsv" ) 2>/dev/null
}
led_bounded() {  # STATE_DIR field...
  run_limited 3 bash -c 'source "$1"; shift; ledger_append "$@"' _ "${BASH_SOURCE[0]}" "$@" >/dev/null 2>&1
}
