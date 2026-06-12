#!/usr/bin/env bash
# crewboss-integrator.sh — integrator-cycle helpers (issue #70).
#
# Subcommands:
#   close-leaf <leaf-id> [--merge-sha SHA] [--repo OWNER/REPO]
#       After PR merge into charter/C: close the leaf issue via gh CLI with a
#       comment containing the merge-SHA so dependents (Depends-on: #<leaf-id>)
#       become launchable on the next cycle.
#
#   gate-charter <charter-id> [--harness SCRIPT] [--remote URL]
#                             [--repo-dir DIR] [--repo OWNER/REPO]
#       Pre-merge gate for charter/C -> main: runs behavioral harness AND
#       marker-grep on ALL files (incl. *.css) in the charter branch tree.
#       Exit 0 = green (safe to merge); exit 1 = red (blocks merge).
#
#       --remote URL   Clone charter/<id> from URL into a temp dir and scan
#                      that tree (production default).  Avoids false-RED from
#                      CWD self-matches and ensures the real branch is checked.
#       --repo-dir DIR Explicit override: scan DIR instead of cloning remote
#                      (for tests/local debug only).  Takes precedence over
#                      --remote.
#
#       CB_HARNESS contract:
#         A local shell command (no existing PR required — anti-deadlock
#         invariant from charter-finale RED-e).  Executed in the root of the
#         charter branch tree (tmpdir when --remote, repo-dir when --repo-dir).
#         Deploy-env wiring (box env vars, paths) is in leaf F9; only the
#         semantics are defined here.
#
# Env: CB_REPO  — default owner/repo for gh calls
set -uo pipefail

log() { printf '[integrator] %s\n' "$*"; }

# ── subcommand: close-leaf ────────────────────────────────────────────────────
cmd_close_leaf() {
  local id="${1:-}"; shift || true
  local merge_sha="" repo="${CB_REPO:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --merge-sha) merge_sha="$2"; shift ;;
      --repo)      repo="$2"; shift ;;
    esac; shift
  done
  [ -n "$id" ] || { log "close-leaf: missing leaf id"; exit 1; }
  local repo_flag=()
  [ -n "$repo" ] && repo_flag=(-R "$repo")

  local comment="Closed by integrator after PR merge"
  [ -n "$merge_sha" ] && comment="Closed by integrator after merge ${merge_sha}"

  gh issue comment "$id" "${repo_flag[@]}" --body "$comment" 2>/dev/null || true
  gh issue close   "$id" "${repo_flag[@]}"
  log "closed leaf #$id (merge-sha: ${merge_sha:-n/a})"
}

# ── marker-grep ───────────────────────────────────────────────────────────────
# Searches ALL file types (including *.css) for leftover debug/gate-bypass markers.
# Old box logic excluded *.css — markers in stylesheets passed the gate silently.
# This version is exhaustive: every text file type is scanned.
# Returns: list of files containing the marker (empty = clean).
# Default pattern: split across two strings so this source file does NOT
# self-match when the charter-branch tree is scanned for gate-bypass markers.
_mkp_prefix="CREWBOSS_NO"
MARKER_PATTERN="${CREWBOSS_MARKER_PATTERN:-${_mkp_prefix}GATE}"

marker_grep() {
  local dir="${1:-.}"
  find "$dir" -type f \
    \( -name "*.sh"   -o -name "*.bash" \
    -o -name "*.js"   -o -name "*.mjs"  -o -name "*.cjs" \
    -o -name "*.ts"   -o -name "*.tsx" \
    -o -name "*.css"  -o -name "*.scss" \
    -o -name "*.json" -o -name "*.html" \
    -o -name "*.md"   -o -name "*.txt" \
    \) \
    ! -path "*/.git/*" \
    ! -path "*/node_modules/*" \
    | xargs grep -l "$MARKER_PATTERN" 2>/dev/null || true
}

# ── subcommand: gate-charter ──────────────────────────────────────────────────
cmd_gate_charter() {
  local charter_id="${1:-}"; shift || true
  [ -n "$charter_id" ] || { log "gate-charter: missing charter id"; exit 1; }
  local harness="" repo_dir="" remote="" repo="${CB_REPO:-}"
  local _repo_dir_explicit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)  harness="$2"; shift ;;
      --repo-dir) repo_dir="$2"; _repo_dir_explicit=1; shift ;;
      --remote)   remote="$2"; shift ;;
      --repo)     repo="$2"; shift ;;
    esac; shift
  done

  # Determine the directory to scan:
  #   1. --repo-dir (explicit override for tests/debug) takes highest priority.
  #   2. --remote: clone charter/<id> into a tmpdir and scan that tree.
  #   3. Fallback: CWD (legacy, no remote configured).
  local tmpdir="" scan_dir="."
  if [ "$_repo_dir_explicit" = "1" ]; then
    scan_dir="$repo_dir"
  elif [ -n "$remote" ]; then
    tmpdir="$(mktemp -d)"
    local branch="charter/$charter_id"
    git clone -q "$remote" "$tmpdir" 2>/dev/null || {
      log "gate-charter #$charter_id: clone from $remote failed"
      rm -rf "$tmpdir"; exit 1
    }
    git -C "$tmpdir" fetch -q origin "$branch" 2>/dev/null && \
      git -C "$tmpdir" checkout -q "FETCH_HEAD" -- 2>/dev/null || {
      log "gate-charter #$charter_id: cannot checkout branch $branch from $remote"
      rm -rf "$tmpdir"; exit 1
    }
    scan_dir="$tmpdir"
  fi

  # 1. Behavioral harness — executed in scan_dir (no existing PR required).
  if [ -n "$harness" ]; then
    log "gate-charter #$charter_id: running harness: $harness"
    if ! (cd "$scan_dir" && bash "$harness"); then
      log "gate-charter #$charter_id: HARNESS RED — merge blocked"
      [ -n "$tmpdir" ] && rm -rf "$tmpdir"; exit 1
    fi
    log "gate-charter #$charter_id: harness green"
  fi

  # 2. Marker-grep — ALL files including *.css, scanned in branch tree.
  log "gate-charter #$charter_id: marker-grep in $scan_dir"
  local hits; hits="$(marker_grep "$scan_dir")"
  if [ -n "$hits" ]; then
    log "gate-charter #$charter_id: MARKER-GREP RED — files with markers:"
    printf '%s\n' "$hits" >&2
    [ -n "$tmpdir" ] && rm -rf "$tmpdir"; exit 1
  fi
  log "gate-charter #$charter_id: marker-grep green"
  log "gate-charter #$charter_id: GATE GREEN — safe to merge"
  if [ -n "$tmpdir" ]; then rm -rf "$tmpdir"; fi
}

# ── subcommand: try-merge ─────────────────────────────────────────────────────
# Dry-run merge of <branch> into <target> against --remote REMOTE_URL.
# Clones into a throwaway tmpdir (NO push).
# exit 0  → merge would be clean
# exit 1  → conflict (conflicting file paths printed on stdout)
cmd_try_merge() {
  local branch="${1:-}" target="${2:-}"
  [ -n "$branch" ] || { log "try-merge: missing branch argument"; exit 1; }
  [ -n "$target" ] || { log "try-merge: missing target argument"; exit 1; }
  shift 2 || true
  local remote=""
  while [ $# -gt 0 ]; do
    case "$1" in --remote) remote="$2"; shift ;; esac; shift
  done
  [ -n "$remote" ] || { log "try-merge: --remote is required"; exit 1; }

  local tmpdir; tmpdir="$(mktemp -d)"

  git clone -q "$remote" "$tmpdir" 2>/dev/null || {
    log "try-merge: clone failed ($remote)"; rm -rf "$tmpdir"; exit 2
  }
  git -C "$tmpdir" config user.email "integrator@crewboss" 2>/dev/null
  git -C "$tmpdir" config user.name  "crewboss-integrator"  2>/dev/null

  git -C "$tmpdir" fetch -q origin "$target" "$branch" 2>/dev/null || {
    log "try-merge: fetch of $target / $branch failed"; rm -rf "$tmpdir"; exit 2
  }
  git -C "$tmpdir" checkout -q -b "_integrator_try" "origin/$target" 2>/dev/null || {
    log "try-merge: checkout of $target failed"; rm -rf "$tmpdir"; exit 2
  }

  local rc=0
  git -C "$tmpdir" merge --no-commit --no-ff "origin/$branch" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    rm -rf "$tmpdir"
    exit 0
  else
    # Print conflicting file paths (one per line)
    git -C "$tmpdir" ls-files --unmerged 2>/dev/null \
      | awk '{print $NF}' | sort -u || true
    rm -rf "$tmpdir"
    exit 1
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  close-leaf)   shift; cmd_close_leaf "$@" ;;
  gate-charter) shift; cmd_gate_charter "$@" ;;
  try-merge)    shift; cmd_try_merge "$@" ;;
  *)
    printf 'usage: %s {close-leaf|gate-charter|try-merge} ...\n' "$(basename "$0")" >&2
    exit 64 ;;
esac
