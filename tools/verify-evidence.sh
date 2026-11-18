#!/usr/bin/env bash
# verify-evidence.sh — run a check and print a Markdown evidence block tied to a commit.
#
# "It passed" is not evidence. This prints WHICH command ran, on WHICH commit,
# with what exit code, plus a hash of the full log, so a reviewer can match it
# to the PR head and rerun it. Local evidence helps a reviewer; it is not a gate.
# The real gate is CI rerunning the checks on that SHA in a clean checkout.
#
# Usage (from inside the repo):
#   verify-evidence.sh [--tests-re <regex>] [--base <ref>] [--log-dir <dir>] [--tail N] -- <command> [args...]
#   verify-evidence.sh ... -- 'npx tsc --noEmit && npm test'   # one quoted string runs in bash -c
# The block shows no log text and no local path unless you pass --tail N.
# Exit: the command's exit code; 90 if the evidence is invalid (tree or HEAD changed
# during the run, hidden files, or --tests-re given but test edits could not be checked);
# 64 for usage errors or a dirty tree.
set -uo pipefail
die() { echo "verify-evidence: $1" >&2; exit "${2:-64}"; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
dirty() { local s; s="$(git status --porcelain --untracked-files=normal)" || return 0; [[ -n "$s" ]]; }
hidden() { git ls-files -v | grep -q '^[a-zS]'; }   # skip-worktree / assume-unchanged hide edits from git status

tests_re="" base="" tail_n=0 logdir="${XDG_STATE_HOME:-$HOME/.local/state}/verify-evidence"
while (($#)); do
  case "$1" in
    --tests-re) tests_re="${2:?}"; shift 2 ;;
    --base) base="${2:?}"; shift 2 ;;
    --log-dir) logdir="${2:?}"; shift 2 ;;
    --tail) tail_n="${2:?}"; [[ "$tail_n" =~ ^[0-9]+$ ]] || die "--tail needs a number"; shift 2 ;;
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
if [[ -n "$tests_re" ]]; then
  if [[ -z "$base" ]] || ! git rev-parse -q --verify "$base^{commit}" >/dev/null || ! mb="$(git merge-base "$base" HEAD 2>/dev/null)"; then
    echo "- Existing tests changed: **UNKNOWN** (no valid base; pass --base)"; valid=0
  elif [[ "$mb" == "$sha" ]]; then
    echo "- Existing tests changed: **UNKNOWN** (base \`$base\` already contains HEAD; pass the base the change started from)"; valid=0
  elif ! ns="$(git -c core.quotePath=false diff --name-status "$mb" HEAD)"; then
    echo "- Existing tests changed: **UNKNOWN** (diff failed)"; valid=0
  else
    # Net change vs base, plus any commit in the branch that modified a test file
    # (catches "add a test, then weaken it" inside the same PR).
    touched="$( { printf '%s\n' "$ns"; git -c core.quotePath=false log --format= --name-status "$mb"..HEAD; } \
      | awk -F'\t' '$1 ~ /^(M|D|R|T)/ {print $2}' | grep -E -- "$tests_re" | sort -u || true)"
    if [[ -n "$touched" ]]; then
      echo "- Existing tests changed vs \`$base\` (need an independent reviewer):"
      printf '%s\n' "$touched" | sed 's/^/  - `/; s/$/`/'
    else
      echo "- Existing tests changed vs \`$base\`: none"
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
