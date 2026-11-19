#!/usr/bin/env bash
# verify-evidence.sh — run a check and print a Markdown evidence block tied to a commit.
#
# "It passed" is not evidence. This prints WHICH command ran, on WHICH commit,
# with what exit code, plus a hash of the full log, so a reviewer can match it
# to the PR head and rerun it. Local evidence helps a reviewer; it is not a gate.
# The real gate is CI rerunning the checks on that SHA in a clean checkout.
#
# Usage (from inside the repo):
#   verify-evidence.sh [--tests-re <regex>] [--base <ref>] [--log-dir <dir>] [--tail N] [--tool <name>]... -- <command> [args...]
#   verify-evidence.sh ... -- 'npx tsc --noEmit && npm test'   # one quoted string runs in bash -c
# The block prints log text only with --tail N. Tool paths mask the home folder,
# other users' folders under /Users or /home, and names under /Volumes.
# With --tests-re, tests added in this branch and edited again later have their
# own heading immediately after the existing-tests report.
# A renamed existing test is listed under "Existing tests changed" by its deleted name, and under the added heading by its new name if edited again.
# Exit: the command's exit code; 90 if the evidence is invalid (tree or HEAD changed
# during the run, hidden files, or --tests-re given but test edits could not be checked);
# 64 for usage errors or a dirty tree.
set -uo pipefail
die() { echo "verify-evidence: $1" >&2; exit "${2:-64}"; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
dirty() { local s; s="$(git status --porcelain --untracked-files=normal)" || return 0; [[ -n "$s" ]]; }
# skip-worktree / assume-unchanged hide edits from git status. Read the whole list
# (no grep -q under pipefail) and treat a git failure as "hidden".
hidden() { local l; l="$(git ls-files -v)" || return 0; grep '^[a-zS]' <<<"$l" >/dev/null; }

tests_re="" base="" tail_n=0 logdir="${XDG_STATE_HOME:-$HOME/.local/state}/verify-evidence"
tool_names=(node python3)
while (($#)); do
  case "$1" in
    --tests-re) tests_re="${2:?}"; shift 2 ;;
    --base) base="${2:?}"; shift 2 ;;
    --log-dir) logdir="${2:?}"; shift 2 ;;
    --tail) tail_n="${2:?}"; [[ "$tail_n" =~ ^[0-9]+$ ]] || die "--tail needs a number"; shift 2 ;;
    --tool)
      [[ "${2:-}" =~ ^[A-Za-z0-9._+-]+$ ]] || die "--tool needs a name matching ^[A-Za-z0-9._+-]+$"
      tool_names+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) die "unknown option $1 (put the command after --)" ;;
  esac
done
(($#)) || die "no command given (put it after --)"
if [[ -n "$tests_re" ]]; then printf '' | grep -E "$tests_re" >/dev/null 2>&1; [[ $? -le 1 ]] || die "--tests-re is not a valid regex"; fi

[[ "$logdir" = /* ]] || logdir="$PWD/$logdir"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$root" || exit 64
status="$(git status --porcelain --untracked-files=normal)" || die "git status failed"
[[ -z "$status" ]] || die "working tree is not clean; commit first so the evidence belongs to a commit"
! hidden || die "some files are marked skip-worktree or assume-unchanged; clear that first (git ls-files -v)"
sha="$(git rev-parse --verify HEAD)" || die "no HEAD commit"
branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "$base" ]]; then
  base="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ -n "$base" ]] || { git rev-parse -q --verify origin/main >/dev/null && base=origin/main; }
  [[ -n "$base" ]] || { git rev-parse -q --verify origin/master >/dev/null && base=origin/master; }
fi

# The log lives outside the work tree so writing it never dirties the tree.
mkdir -p "$logdir" || die "cannot create $logdir"
rlog="$(cd "$logdir" && pwd -P)"; rroot="$(pwd -P)"
[[ "$rlog" == "$rroot" || "$rlog" == "$rroot"/* ]] && die "--log-dir must be outside the work tree"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="$(mktemp "$logdir/${sha:0:12}-$stamp.XXXXXX")" || die "mktemp failed"

probe_version() (
  local output
  output="$(mktemp "$logdir/version.XXXXXX")" || return 1
  trap 'rm -f "$output"' EXIT
  if [[ -n "$timeout_path" ]]; then
    "$timeout_path" -s KILL 5 "$1" --version </dev/null >"$output" 2>&1 || return 1
  elif [[ -n "$perl_path" ]]; then
    "$perl_path" -e '
      my $pid = fork();
      defined $pid or exit 1;
      if (!$pid) { setpgrp(0, 0) or exit 1; exec @ARGV or exit 127 }
      $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; exit 124 };
      alarm 5;
      waitpid($pid, 0) == $pid or exit 1;
      exit($? == 0 ? 0 : 1);
    ' "$1" --version </dev/null >"$output" 2>&1 || return 1
  else
    return 1
  fi
  # Treat bare CR as a line boundary too, so overwritten terminal text stays out.
  head -n 1 "$output" | sed $'s/\r.*//' | tr -d '[:cntrl:]`<>'
)

timeout_path="$(type -P timeout)"
perl_path="$(type -P perl)"
tool_home="${HOME:-}"
while [[ "$tool_home" == */ ]]; do tool_home="${tool_home%/}"; done
tools_on_path="" found_tool=0
for name in "${tool_names[@]}"; do
  if path="$(type -P -- "$name")"; then
    found_tool=1
    version="$(probe_version "$path" 2>/dev/null)" || version="?"
    version="${version:0:40}"
    if [[ "$version" == *[[:blank:]]* ]]; then
      prefix="${version%%[[:blank:]]*}"
      if [[ "$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" ||
            ( "$name" == python3 && "$prefix" == Python ) ]]; then
        version="${version#"$prefix"}"
        version="${version#"${version%%[![:blank:]]*}"}"
      fi
    fi
    if [[ -n "$tool_home" && "$path" == "$tool_home"/* ]]; then
      path="~/${path#"$tool_home"/}"
    elif [[ "$path" == /Users/?*/* || "$path" == /home/?*/* ]]; then
      rest="${path#/*/}"
      path="~other/${rest#*/}"
    fi
    if [[ "$path" == /Volumes/?*/* ]]; then
      rest="${path#/Volumes/}"
      path="/Volumes/…/${rest#*/}"
    fi
    entry="$name ${version:-?} ($path)"
  else
    entry="$name not found"
  fi
  tools_on_path+="${tools_on_path:+; }$entry"
done
if ((!found_tool && ${#tool_names[@]} == 2)); then
  tools_on_path="none of node, python3 found"
fi

start=$SECONDS
if (($# == 1)); then bash -c "$1" >"$log" 2>&1; rc=$?; else "$@" >"$log" 2>&1; rc=$?; fi
secs=$((SECONDS - start))
hash="$(sha256 "$log")"; [[ ${#hash} == 64 ]] || die "could not hash the log" 3
valid=1
[[ "$(git rev-parse --verify HEAD 2>/dev/null)" == "$sha" ]] || valid=0
dirty && valid=0
hidden && valid=0

if (($# == 1)); then cmd="$1 "; else cmd="$(printf '%q ' "$@")"; fi
echo "### Verification evidence"
echo "- Commit: \`$sha\` ($branch)"
echo "- Command: \`${cmd% }\`"
echo "- Exit code: **$rc** ($([[ $rc == 0 ]] && echo pass || echo FAIL))"
echo "- Ran at (UTC): $stamp, ${secs}s"
echo "- Full log: kept on this machine as \`$(basename "$log")\` (sha256 \`$hash\`)"
printf -- '- Tools on PATH: %s\n' "$tools_on_path"
if [[ -n "$tests_re" ]]; then
  if [[ -z "$base" ]] || ! git rev-parse -q --verify "$base^{commit}" >/dev/null || ! mb="$(git merge-base "$base" HEAD 2>/dev/null)"; then
    echo "- Existing tests changed: **UNKNOWN** (no valid base; pass --base)"; valid=0
  elif [[ "$mb" == "$sha" ]]; then
    echo "- Existing tests changed: **UNKNOWN** (base \`$base\` already contains HEAD; pass the base the change started from)"; valid=0
  elif ! nsz="$(mktemp "$logdir/ns.XXXXXX")" || ! { git diff -z --no-renames --name-status "$mb" HEAD \
           && git log -z --no-renames --format= --name-status "$mb"..HEAD; } >"$nsz" 2>/dev/null; then
    echo "- Existing tests changed: **UNKNOWN** (git diff/log failed)"; valid=0; rm -f "${nsz:-}"
  else
    # Net change vs base, plus any commit in the branch that modified a test file
    # (catches "add a test, then weaken it" inside the same PR). NUL-separated, so
    # unusual file names are read exactly.
    existing=() added=()
    while IFS= read -r -d '' f; do
      if git cat-file -e "$mb:$f" 2>/dev/null; then
        existing+=("${f//$'\n'/\\n}")
      else
        added+=("${f//$'\n'/\\n}")
      fi
    done < <(
      while IFS= read -r -d '' st; do
        st="${st#$'\n'}"; [[ -n "$st" ]] || continue
        IFS= read -r -d '' f || break
        if [[ "$st" =~ ^[MDT]$ && "$f" =~ $tests_re ]]; then
          printf '%s\0' "$f"
        fi
      done < "$nsz" | sort -zu
    )
    rm -f "$nsz"
    if [[ -n "${existing[0]:-}" ]]; then
      echo "- Existing tests changed vs \`$base\` (need an independent reviewer):"
      printf '  - `%s`\n' "${existing[@]}"
    else
      echo "- Existing tests changed vs \`$base\`: none"
    fi
    if [[ -n "${added[0]:-}" ]]; then
      echo '- Tests added in this branch and edited again later (check they were not weakened):'
      printf '  - `%s`\n' "${added[@]}"
    fi
  fi
fi
((valid)) || echo "- **INVALID**: the tree or HEAD changed during the run, files are hidden from git, or test edits could not be checked. Do not use this evidence."
if ((tail_n > 0)); then
  # Off by default: logs can hold local paths, account names or secrets. Read before pasting publicly.
  echo
  echo "<details><summary>Last $tail_n lines of the log (check before posting)</summary>"
  echo
  echo '```'
  tail -n "$tail_n" "$log"
  echo '```'
  echo "</details>"
fi
((valid)) || exit 90
exit "$rc"
