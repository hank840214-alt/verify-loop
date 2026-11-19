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
  # TERM or INT sent to this wrapper (for example by an outer watchdog or the host) is forwarded to
  # the command's group, so nothing is left running behind it. Wrappers nest (hook -> inner hook ->
  # check). RL_DEPTH counts the levels, and an outer level waits longer between TERM and KILL than
  # an inner one, so the inner level always gets to KILL its group before it is itself killed.
  perl -e '
    use Time::HiRes qw(time sleep);
    my $t = shift; $t = 1 if $t < 1;
    my $d = $ENV{RL_DEPTH} || 0; $ENV{RL_DEPTH} = $d + 1;
    my $grace = 0.2 + 0.5 * (3 - ($d > 3 ? 3 : $d));
    my $pid = fork(); defined $pid or exit 127;
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    setpgrp($pid, $pid);
    my $stop = sub {
      kill "TERM", -$pid; my $end = time + $grace;
      while (time < $end) { waitpid($pid, 1); last if !kill(0, -$pid); sleep(0.05) }
      kill "KILL", -$pid;
    };
    $SIG{ALRM} = sub { $stop->(); exit 124 };
    $SIG{TERM} = $SIG{INT} = sub { $stop->(); exit 143 };
    alarm $t; waitpid($pid, 0); my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}
clean_tabs() { printf '%s' "${1//[$'\t\r\n']/_}"; }

# One ledger line: ledger_append STATE_DIR field... (tab separated, mode 600). The whole row is built
# first and written with one printf, so concurrent hooks cannot interleave their fields.
# led_bounded runs it under a short time limit, so a stuck file system cannot hold the hook past
# its watchdog.
ledger_append() {
  local dir="$1" row f; shift
  row="$(date -u +%FT%TZ)"
  for f in "$@"; do row="$row"$'\t'"$(clean_tabs "$f")"; done
  ( umask 077; mkdir -p "$dir" && printf '%s\n' "$row" >> "$dir/ledger.tsv" ) 2>/dev/null
}
led_bounded() {  # STATE_DIR field...
  run_limited 3 bash -c 'source "$1"; shift; ledger_append "$@"' _ "${BASH_SOURCE[0]}" "$@" >/dev/null 2>&1
}

# pick_conf: the projects file to use. $STOP_VERIFY_CONFIG counts only if it is an absolute path to
# a regular file (not a link) whose physical folder is under $HOME/.claude or $HOME/.config.
# Otherwise the default ~/.claude/stop-verify.projects.json. (stop-verify.sh itself accepts any
# absolute path.)
pick_conf() {
  local def="$HOME/.claude/stop-verify.projects.json" x="${STOP_VERIFY_CONFIG:-}" d f b h
  if [[ "$x" == /* ]]; then
    # Resolve the folder physically first, build the final path from it, and run every check on
    # that final path: it is exactly the path later given to jq.
    d="$(cd -P "$(dirname "$x")" 2>/dev/null && pwd -P)" || { printf '%s' "$def"; return 0; }
    f="$d/${x##*/}"
    if [[ -f "$f" && ! -L "$f" ]]; then
      for b in "$HOME/.claude" "$HOME/.config"; do
        h="$(cd -P "$b" 2>/dev/null && pwd -P)" || continue
        if [[ "$d" == "$h" || "$d" == "$h"/* ]]; then printf '%s' "$f"; return 0; fi
      done
    fi
  fi
  printf '%s' "$def"
}
