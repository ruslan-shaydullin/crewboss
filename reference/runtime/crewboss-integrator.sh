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
#   try-merge <branch> <target> --remote URL
#       Dry-run merge of <branch> into <target> against --remote URL.
#       Clones into a throwaway tmpdir (NO push).
#       exit 0 → merge would be clean
#       exit 1 → conflict (conflicting file paths printed on stdout)
#       exit 2 → infra (clone/fetch/checkout broken)
#
#   verify-merged <leaf-branch> <target-branch> --remote URL
#                 [--repo OWNER/REPO] [--verdict-file PATH]
#       Build merged tree (leaf merged into target-branch, same mechanism as
#       try-merge clone+fetch+merge) and run engine test suite on it.
#       Catches semantic breakage that only surfaces AFTER merge (F4 risk-1:
#       leaf green in isolation, broken together with siblings/charter).
#       NOT a freshness check (F4-restructure; charter↔main freshness held
#       by finale ancestor-check #156).
#
#       --verdict-file PATH  Write machine-readable verdict to PATH:
#                            'pass' / 'fail' / 'infra' (no newline).
#
#       CB_HARNESS contract (verify-merged extension, issue #174):
#         Merged-tree = try-merge mechanism (fresh git clone from --remote,
#         leaf merged --no-commit --no-ff into target-branch).  Engine suite =
#         reference/tests/*.test.sh run from the clone root (reference/bin/ and
#         reference/tests/ come from the clone, NOT from ~/cbnet box-deploy).
#         F1 nullglob: shopt -s nullglob before test loop; empty suite
#         (no *.test.sh files) = pass (not a literal-string bash crash).
#         F2 timeout: engine run wrapped in timeout "${CB_VERIFY_TIMEOUT:-600}";
#         exit 124 (timeout exceeded) → infra verdict (exit 2), not fail —
#         a hanging test must not block the host loop.
#         Exit codes: 0=pass (engine green on merged tree; empty suite also pass),
#                     1=fail (engine RED on merged tree),
#                     2=infra (clone/fetch/checkout/merge failed OR timeout).
#         Host executes arbitrary pushed bash outside jail; sole runtime
#         constraint: CB_VERIFY_TIMEOUT (default 600 s).
#
# Env: CB_REPO            — default owner/repo for gh calls
#      CB_VERIFY_TIMEOUT  — verify-merged engine-run timeout in seconds (default 600)
#      CB_VERIFY_CACHE    — verdict cache directory for verify-merged (#175).
#                           Default: $CB_HOME/run/verify-cache when CB_HOME is set,
#                           otherwise a mktemp per-run directory (no persistence).
#                           L4 (#177) wires this to the production env.
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
  # Capture exit code explicitly — set -uo pipefail does NOT abort on standalone
  # command failure (no -e), so we must check it ourselves and propagate it.
  local close_exit=0
  gh issue close   "$id" "${repo_flag[@]}" || close_exit=$?
  if [ "$close_exit" -ne 0 ]; then
    log "close-leaf: gh issue close #$id failed (exit $close_exit) — caller should retry"
    exit "$close_exit"
  fi
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
      log "gate-charter #$charter_id: clone failed (charter $charter_id)"
      rm -rf "$tmpdir"; exit 1
    }
    git -C "$tmpdir" fetch -q origin "$branch" 2>/dev/null && \
      git -C "$tmpdir" checkout -q "FETCH_HEAD" -- 2>/dev/null || {
      log "gate-charter #$charter_id: cannot checkout branch $branch"
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

# ── helper: _build_merged_tree ────────────────────────────────────────────────
# Clones <remote> into a fresh tmpdir, configures git user, fetches <target>
# and <branch>, checks out origin/<target> as <checkout_name>, then merges
# --no-commit --no-ff origin/<branch>.
#
# Output: sets _BMT_DIR to the tmpdir path on success and on conflict.
#         On infra failure _BMT_DIR is cleaned up and set to "".
# Returns:
#   0  → merge clean; _BMT_DIR contains the merged tree ready to use.
#   1  → merge conflict; _BMT_DIR still valid (caller can inspect ls-files).
#   2  → infra failure (clone/fetch/checkout broken); _BMT_DIR cleaned and "".
#
# Caller MUST rm -rf "$_BMT_DIR" when done (unless return was 2).
_BMT_DIR=""
_build_merged_tree() {
  local branch="$1" target="$2" remote="$3" checkout_name="${4:-_integrator_try}"
  _BMT_DIR="$(mktemp -d)"

  git clone -q "$remote" "$_BMT_DIR" 2>/dev/null || {
    log "_build_merged_tree: clone failed"
    rm -rf "$_BMT_DIR"; _BMT_DIR=""; return 2
  }
  git -C "$_BMT_DIR" config user.email "integrator@crewboss" 2>/dev/null
  git -C "$_BMT_DIR" config user.name  "crewboss-integrator"  2>/dev/null

  git -C "$_BMT_DIR" fetch -q origin "$target" "$branch" 2>/dev/null || {
    log "_build_merged_tree: fetch of $target / $branch failed"
    rm -rf "$_BMT_DIR"; _BMT_DIR=""; return 2
  }
  git -C "$_BMT_DIR" checkout -q -b "$checkout_name" "origin/$target" 2>/dev/null || {
    log "_build_merged_tree: checkout of $target failed"
    rm -rf "$_BMT_DIR"; _BMT_DIR=""; return 2
  }

  local rc=0
  git -C "$_BMT_DIR" merge --no-commit --no-ff "origin/$branch" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# ── subcommand: try-merge ─────────────────────────────────────────────────────
# Dry-run merge of <branch> into <target> against --remote REMOTE_URL.
# Clones into a throwaway tmpdir (NO push).
# exit 0  → merge would be clean
# exit 1  → conflict (conflicting file paths printed on stdout)
# exit 2  → infra (clone/fetch/checkout broken)
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

  local bmt_rc=0
  _build_merged_tree "$branch" "$target" "$remote" "_integrator_try" || bmt_rc=$?

  if [ "$bmt_rc" -eq 2 ]; then
    exit 2
  elif [ "$bmt_rc" -eq 0 ]; then
    rm -rf "$_BMT_DIR"
    exit 0
  else
    # Print conflicting file paths (one per line)
    git -C "$_BMT_DIR" ls-files --unmerged 2>/dev/null \
      | awk '{print $NF}' | sort -u || true
    rm -rf "$_BMT_DIR"
    exit 1
  fi
}

# ── cache: resolve verify-merged verdict cache directory ──────────────────────
# Priority: CB_VERIFY_CACHE > $CB_HOME/run/verify-cache > mktemp per-run.
# When neither CB_VERIFY_CACHE nor CB_HOME is set, each invocation of
# verify-merged creates a fresh tmpdir — the cache works only within that single
# call (effectively no cross-call persistence), which is safe.
_resolve_verify_cache_dir() {
  if [ -n "${CB_VERIFY_CACHE:-}" ]; then
    printf '%s' "${CB_VERIFY_CACHE}"
  elif [ -n "${CB_HOME:-}" ]; then
    printf '%s' "${CB_HOME}/run/verify-cache"
  else
    mktemp -d
  fi
}

# ── subcommand: verify-merged ─────────────────────────────────────────────────
# Build merged tree (leaf merged into target-branch, reusing _build_merged_tree)
# and run engine test suite (reference/tests/*.test.sh) on the result.
# Catches semantic breakage after merge: leaf green in isolation, broken with
# siblings/charter (F4 risk-1).  NOT a freshness check (F4-restructure).
#
# exit 0  → pass (engine green on merged tree; empty suite also pass — F1)
# exit 1  → fail (engine RED on merged tree)
# exit 2  → infra (clone/fetch/checkout/merge broken OR timeout — F2)
#
# --verdict-file PATH  Write 'pass'/'fail'/'infra' to PATH (machine-readable).
# CB_VERIFY_TIMEOUT    Engine-run timeout in seconds (default 600).
# CB_VERIFY_CACHE      Verdict cache dir (#175, F3 key = leaf_sha+target_base_sha).
#
# F3 cache (issue #175):
#   Cache key = leaf-sha + target-base-sha (both resolved via git ls-remote before
#   clone).  If the target branch advances (sibling merged in), target-base-sha
#   changes → cache miss → full re-run (does not mask semantic breakage after the
#   new sibling lands).  A cache keyed only on leaf-sha would be a hole (F3): the
#   base could shift while the leaf stays the same → stale pass served.
#   Only pass/fail are cached; infra (exit 2) is never stored — retry on next tick.
#
# F1 nullglob: shopt -s nullglob before test loop; no *.test.sh → empty loop
#   → pass.  Without nullglob, bash would pass the literal glob string to bash
#   as a script path → false fail.
# F2 timeout: timeout exit 124 → infra (exit 2), not fail.  A hanging test
#   must not block the host integration loop.
# Security note: host executes arbitrary pushed bash outside jail; sole runtime
#   constraint is CB_VERIFY_TIMEOUT.
cmd_verify_merged() {
  local branch="${1:-}" target="${2:-}"
  [ -n "$branch" ] || { log "verify-merged: missing branch argument"; exit 2; }
  [ -n "$target" ] || { log "verify-merged: missing target argument"; exit 2; }
  shift 2 || true
  local remote="" repo="${CB_REPO:-}" verdict_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote)       remote="$2"; shift ;;
      --repo)         repo="$2"; shift ;;
      --verdict-file) verdict_file="$2"; shift ;;
    esac; shift
  done
  [ -n "$remote" ] || { log "verify-merged: --remote is required"; exit 2; }

  # ── F3 verdict cache (issue #175) ────────────────────────────────────────
  # Key = leaf_sha + target_base_sha.  Both SHAs resolved from the remote NOW
  # (before cloning) so that any base movement (sibling merged) invalidates the
  # key.  Only pass/fail cached; infra never stored.
  local _leaf_sha="" _base_sha="" _cache_dir="" _cache_key="" _cache_file=""
  _leaf_sha=$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | awk '{print $1}')
  _base_sha=$(git ls-remote "$remote" "refs/heads/$target" 2>/dev/null | awk '{print $1}')

  if [ -n "$_leaf_sha" ] && [ -n "$_base_sha" ]; then
    _cache_dir="$(_resolve_verify_cache_dir)"
    mkdir -p "$_cache_dir" 2>/dev/null || true
    _cache_key="${_leaf_sha}_${_base_sha}"
    _cache_file="${_cache_dir}/${_cache_key}"

    if [ -f "$_cache_file" ]; then
      local _cached
      _cached="$(cat "$_cache_file" 2>/dev/null)"
      case "$_cached" in
        pass)
          log "verify-merged: cache hit ($_cache_key) → pass"
          [ -n "$verdict_file" ] && printf 'pass' > "$verdict_file"
          exit 0 ;;
        fail)
          log "verify-merged: cache hit ($_cache_key) → fail"
          [ -n "$verdict_file" ] && printf 'fail' > "$verdict_file"
          exit 1 ;;
        # infra or unknown in cache file: ignore — fall through to full re-run
      esac
    fi
  fi

  # 1. Build merged tree (reuses _build_merged_tree — same mechanism as try-merge).
  #    Merge conflict or infra failure both yield exit 2 (infra) for verify-merged.
  local bmt_rc=0
  _build_merged_tree "$branch" "$target" "$remote" "_verify" || bmt_rc=$?

  if [ "$bmt_rc" -ne 0 ]; then
    log "verify-merged: failed to build merged tree (infra, code $bmt_rc)"
    [ -n "$_BMT_DIR" ] && { rm -rf "$_BMT_DIR"; _BMT_DIR=""; }
    [ -n "$verdict_file" ] && printf 'infra' > "$verdict_file"
    exit 2
  fi

  local merged_dir="$_BMT_DIR"

  # 2. Run engine suite on the merged tree.
  #    F1: shopt -s nullglob — empty glob → empty loop → pass (not literal-string crash).
  #    F2: background-kill timer (CB_VERIFY_TIMEOUT, default 600s) — if the suite
  #        subshell is killed by the timer, wait returns 128+signum which we normalise
  #        to 124 (timeout convention) → infra (exit 2).
  #    Tests run from the clone root (reference/tests/ and reference/bin/ come from
  #    the clone, not from ~/cbnet box-deploy — HD-2 fresh-clone requirement).
  #    I2 fix (#194): per-leaf ALLOW filter — only leaf-unit-safe tests run here.
  #    Default-exclude (fail-safe/fail-closed): any test NOT in ALLOW is skipped.
  #    Full suite (including EXCLUDED) still runs in GHA (ci.yml:21-33).
  #    Manifest: reference/tests/per-leaf-manifest (ALLOW/EXCLUDED classification).
  local suite_rc=0
  _pl_manifest="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/per-leaf-manifest"

  # Start engine run in background subshell
  (
    cd "$merged_dir"
    shopt -s nullglob
    fail=0
    for t in reference/tests/*.test.sh; do
      _base="$(basename "$t" .test.sh)"
      # Only run tests explicitly classified as ALLOW in the manifest.
      # Unknown/unclassified/EXCLUDED tests are skipped (fail-safe default).
      grep -qE "^ALLOW[[:space:]]+${_base}$" "$_pl_manifest" 2>/dev/null || continue
      bash "$t" || fail=1
    done
    exit "$fail"
  ) &
  local suite_pid=$!

  # Background timer: kill the suite subshell after CB_VERIFY_TIMEOUT seconds
  ( sleep "${CB_VERIFY_TIMEOUT:-600}" 2>/dev/null; kill "$suite_pid" 2>/dev/null ) &
  local timer_pid=$!

  wait "$suite_pid" 2>/dev/null || suite_rc=$?

  # Cancel the timer
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true

  # Normalise signal-kill exit (128+N) to 124 (timeout convention → infra)
  [ "$suite_rc" -gt 128 ] && suite_rc=124

  rm -rf "$merged_dir"
  _BMT_DIR=""

  # 3. Classify result and write verdict.
  local verdict
  if [ "$suite_rc" -eq 0 ]; then
    verdict="pass"
  elif [ "$suite_rc" -eq 1 ]; then
    verdict="fail"
  else
    # exit 124 = timeout (infra); any other non-0/1 also treated as infra
    verdict="infra"
  fi

  [ -n "$verdict_file" ] && printf '%s' "$verdict" > "$verdict_file"

  # Write verdict to cache (only pass/fail; infra is never cached — must retry).
  if [ -n "$_cache_file" ] && [ "$verdict" != "infra" ]; then
    printf '%s' "$verdict" > "$_cache_file"
  fi

  case "$verdict" in
    pass)
      log "verify-merged: PASS (engine green on merged tree)"
      exit 0 ;;
    fail)
      log "verify-merged: FAIL (engine RED on merged tree)"
      exit 1 ;;
    infra)
      log "verify-merged: INFRA (timeout or harness error; suite_rc=$suite_rc)"
      exit 2 ;;
  esac
}

# ── dispatch ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  close-leaf)    shift; cmd_close_leaf "$@" ;;
  gate-charter)  shift; cmd_gate_charter "$@" ;;
  try-merge)     shift; cmd_try_merge "$@" ;;
  verify-merged) shift; cmd_verify_merged "$@" ;;
  *)
    printf 'usage: %s {close-leaf|gate-charter|try-merge|verify-merged} ...\n' \
      "$(basename "$0")" >&2
    exit 64 ;;
esac
