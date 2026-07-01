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

# git shim: when sourced for testing, intercept 'git update-ref MERGE_HEAD SHA'
# which git 2.45+ refuses via update-ref (pseudoref protection). In production
# execution this block never runs — git merge --no-commit writes .git/MERGE_HEAD
# automatically. Only active when sourced (BASH_SOURCE[0] != ${0}).
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  git() {
    if [ "${1:-}" = "-C" ] && [ "${3:-}" = "update-ref" ] && \
       { [ "${4:-}" = "MERGE_HEAD" ] || [ "${4:-}" = "ORIG_HEAD" ]; } && [ -n "${5:-}" ]; then
      local _gd; _gd="$(command git -C "$2" rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$_gd" ] && { printf '%s\n' "$5" > "$_gd/$4"; return 0; }
    fi
    if [ "${1:-}" = "update-ref" ] && \
       { [ "${2:-}" = "MERGE_HEAD" ] || [ "${2:-}" = "ORIG_HEAD" ]; } && [ -n "${3:-}" ]; then
      local _gd; _gd="$(command git rev-parse --absolute-git-dir 2>/dev/null)"
      [ -n "$_gd" ] && { printf '%s\n' "$3" > "$_gd/$2"; return 0; }
    fi
    command git "$@"
  }
fi

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
  gh issue edit "$id" "${repo_flag[@]}" --remove-label "status:review" 2>/dev/null || true
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

# _detect_ui_artifact: detect UI-touching diff and write artifact_type sidecar.
# Args: $1=merged_dir  $2=cache_file
# Returns: 1 if UI charter (diff touches ui/), 0 if non-UI.
# NOTE: contains ONLY git-diff+sidecar — no gh api (ALLOW boundary).
# API/contract path (ui/server/): out of scope — future leaf.
# NOTE: set +e at top propagates to caller so "func; ret=$?" safely captures
# return code 1 in test contexts running set -euo pipefail.  In production the
# integrator runs with set -uo pipefail (no -e), so set +e is a no-op there.
_detect_ui_artifact() {
  set +e
  local merged_dir="$1" cache_file="$2"
  git -C "$merged_dir" diff ORIG_HEAD MERGE_HEAD --name-only 2>/dev/null | grep -q '^ui/' || return 0
  [ -n "$cache_file" ] && printf 'ui' > "${cache_file}.artifact_type"
  return 1
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

  _ui_charter=0
  _detect_ui_artifact "$merged_dir" "$_cache_file" || _ui_charter=1

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
  local _reason_file; _reason_file="$(mktemp 2>/dev/null || echo "/tmp/cb-reason.$$")"

  # Start engine run in background subshell
  (
    cd "$merged_dir"
    # Hermetic env (#238 capstone find): the launcher exports its run-loop scope
    # (CREWBOSS_CHARTER → CHARTER_SCOPE in launchable.sh) and THIS suite subshell
    # inherits it via the launcher's `vm_out=$(... verify-merged ...)`. Engine tests
    # that read CREWBOSS_CHARTER (launchable, cli-smoke, acceptance-block) would then
    # scope their OWN fixture board to the running charter → empty result → false-RED.
    # Latent because production batches run the launcher UNSCOPED (CHARTER_SCOPE=0, no
    # filter); a scoped run (CREWBOSS_CHARTER=<C>) exposes it. Strip the loop-scope so
    # hermetic engine tests run exactly as they do in clean CI.
    unset CREWBOSS_CHARTER CHARTER_SCOPE
    shopt -s nullglob
    # #206 Part A: in-clone sha-lock regen (EPHEMERAL, verdict-only). Refreshes
    # runtime-manifest.tsv to match the merged tree so runtime-manifest (now an
    # ALLOW test, #206 Part B) does NOT false-RED on benign sha-drift while still
    # catching structural breaks (missing row / removed runtime file / wrong
    # status — Test 2/4). This is NOT a persistence path: merged_dir is discarded
    # below (rm -rf). Persistence is EXCLUSIVELY the charter-finale regen-persist
    # commit (#206 Part A). No-op when the tool/manifest is absent (fixtures).
    [ -f reference/bin/regen-manifest.sh ] && \
      bash reference/bin/regen-manifest.sh >/dev/null 2>&1 || exit 2
    fail=0
    for t in reference/tests/*.test.sh; do
      _base="$(basename "$t" .test.sh)"
      # Only run tests explicitly classified as ALLOW in the manifest.
      # Unknown/unclassified/EXCLUDED tests are skipped (fail-safe default).
      grep -qE "^ALLOW[[:space:]]+${_base}$" "$_pl_manifest" 2>/dev/null || continue
      # #1110: capture combined stdout+stderr IN-SUBSHELL via command substitution
      # (no extra fd left open holding the caller's pipe — cf. the load-bearing
      # redirect note below) so the RED reason can surface the EXACT failing
      # assertion, not just the test basename (#1043 blind-fix loop). On failure,
      # extract a BOUNDED single-line detail: grep FAIL/✗/assert markers (each
      # match capped at 200 chars so a megabyte filler line cannot leak), fall back
      # to the tail bytes if no marker, collapse newlines and drop commas (commas
      # are reserved for the downstream `paste -sd,` join), then hard-cap at 200
      # chars. Append "<base>: <detail>" — basename PRESERVED (backwards-compat).
      # Everything downstream (sort -u | paste -sd, / ${_cache_file}.reason /
      # RED_REASON print / smoke-reason / N-confirmation) stays untouched.
      _out="$(bash "$t" 2>&1)"; _trc=$?
      if [ "$_trc" -ne 0 ]; then
        fail=1
        _detail="$(printf '%s\n' "$_out" | grep -aoE '(FAIL|✗|[Aa]ssert)[^[:cntrl:]]{0,200}' 2>/dev/null | head -3 | tr '\n,' ';;')"
        [ -z "$_detail" ] && _detail="$(printf '%s\n' "$_out" | tail -c 200 | tr '\n,' ';;')"
        _detail="$(printf '%s' "$_detail" | cut -c1-200)"
        printf '%s: %s\n' "$_base" "$_detail" >> "$_reason_file"
      fi
    done
    exit "$fail"
  ) &
  local suite_pid=$!

  # Background timer: kill the suite subshell after CB_VERIFY_TIMEOUT seconds.
  # The `>/dev/null 2>&1` on this subshell is LOAD-BEARING: when the timer is
  # cancelled below, its `sleep` child is orphaned (reparented to init). Without the
  # redirect that orphan inherits OUR stdout — and when a caller captures verify-merged
  # via command substitution (the launcher's `vm_out=$(... verify-merged ...)`), the
  # orphaned sleep holds that pipe open until it finally exits, blocking the caller for
  # the FULL timeout on EVERY call. That was the root of the launcher verify-merged
  # "flake" (600 s block → killed/retried under load → false red) AND the O(n²) CI
  # slowness (launcher-loop tests pay ~600 s per verify-merged). Direct callers
  # (--verdict-file, no $()) never saw it — hence leaf-verifier passed.
  ( sleep "${CB_VERIFY_TIMEOUT:-600}" 2>/dev/null; kill "$suite_pid" 2>/dev/null ) >/dev/null 2>&1 &
  local timer_pid=$!

  wait "$suite_pid" 2>/dev/null || suite_rc=$?

  # Cancel the timer
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true

  # Normalise signal-kill exit (128+N) to 124 (timeout convention → infra)
  [ "$suite_rc" -gt 128 ] && suite_rc=124

  # ── Visual regression gate (podman, UI-charter only) ──────────────────────
  # MUST run BEFORE merged_dir cleanup — volume-mount requires the path to exist.
  local _playwright_digest; _playwright_digest=$(cat "$(dirname "$0")/playwright-image.digest" 2>/dev/null || echo "")
  local VISUAL_INFRA_MAX_TICKS=5
  local visual_rc=0
  local _visual_infra_file=""
  [ -n "$_cache_file" ] && _visual_infra_file="${_cache_file}.visual_infra_ticks"

  if [[ "$_ui_charter" -eq 1 ]]; then
    if [[ -n "$_playwright_digest" ]] && ! [[ -f "${CREWBOSS_RUN_DIR:-${CB_HOME:-}/run}/visual_gate_soft" ]]; then
      # Normal path: run container
      docker run --rm \
        -v "$merged_dir/ui/app:/app:rw" \
        -w /app \
        "$_playwright_digest" \
        bash -c "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --silent && node scripts/visual-regression.mjs"
      visual_rc=$?
    else
      # Soft-gate fallback: infra unavailable or sentinel present — do not block
      visual_rc=0
    fi
  fi

  # ── Real-run smoke gate EXECUTION (charter #993) ──────────────────────────
  # MUST run BEFORE merged_dir cleanup — smoke-runner.sh starts REAL processes
  # from the merged tree (mirroring the visual gate above; the original "insert
  # before final classification" plan was rejected because the tree is already
  # rm -rf'd by then). Classification of smoke_rc happens POST-cleanup, in the
  # verdict block below — here we ONLY execute and capture.
  # Self-bootstrap / graceful degrade: if the harness is ABSENT in the merged
  # tree, smoke is a NO-OP pass (smoke_rc=0). This is the fail-safe default that
  # lets charter #993 itself merge through the current (pre-smoke) verify-merged;
  # smoke activates for future leaves once the harness is merged + deployed.
  # FROZEN exit-code contract (#997): 0=PASS, 1=FAIL (artifact proven broken;
  # prints `SMOKE_REASON: <detector>` on stdout), 2/3=INFRA (never a silent pass).
  # A hanging artifact fails BY timeout INSIDE the harness, so this call never
  # blocks the integrator indefinitely.
  local smoke_rc=0 smoke_reason=""
  if [ -f "$merged_dir/reference/runtime/smoke-runner.sh" ]; then
    local _smoke_out
    _smoke_out="$(bash "$merged_dir/reference/runtime/smoke-runner.sh" "$merged_dir" 2>/dev/null)"
    smoke_rc=$?
    smoke_reason="$(printf '%s\n' "$_smoke_out" | sed -n 's/^SMOKE_REASON:[[:space:]]*//p' | head -1)"
  fi

  rm -rf "$merged_dir"
  _BMT_DIR=""

  # Branch on visual_rc after cleanup
  if [[ "$_ui_charter" -eq 1 ]] && [[ "$visual_rc" -ne 0 ]]; then
    if [[ "$visual_rc" -eq 1 ]]; then
      # Visual test failure — fall through to N-confirmation counter
      suite_rc=1
      printf 'RED_REASON: visual-regression-failed\n'
    else
      # Infra error (rc != 0, rc != 1): increment visual_infra_error_ticks counter
      local visual_infra_error_ticks=0
      [ -n "$_visual_infra_file" ] && [ -f "$_visual_infra_file" ] && \
        visual_infra_error_ticks="$(cat "$_visual_infra_file" 2>/dev/null || echo 0)"
      visual_infra_error_ticks=$((visual_infra_error_ticks + 1))
      [ -n "$_visual_infra_file" ] && printf '%s' "$visual_infra_error_ticks" > "$_visual_infra_file"
      local _leaf_issue_id; _leaf_issue_id=$(printf '%s' "$branch" | grep -oE 'leaf/([0-9]+)' | grep -oE '[0-9]+' | head -1 || echo "")
      if [ "$visual_infra_error_ticks" -ge "$VISUAL_INFRA_MAX_TICKS" ]; then
        local _blocked_msg="Visual gate infra unavailable for ${visual_infra_error_ticks} ticks (container/image error rc=${visual_rc}). Manual intervention required. Set run/visual_gate_soft sentinel to unblock temporarily."
        log "verify-merged: $_blocked_msg"
        if [ -n "$_leaf_issue_id" ] && [ -n "${repo:-}" ]; then
          gh issue comment "$_leaf_issue_id" -R "$repo" --body "$_blocked_msg" 2>/dev/null || true
          gh issue edit "$_leaf_issue_id" -R "$repo" --add-label "status:blocked" 2>/dev/null || true
        fi
        [ -n "$verdict_file" ] && printf 'infra' > "$verdict_file"
        exit 1
      else
        log "verify-merged: visual gate infra error (rc=$visual_rc), tick $visual_infra_error_ticks/$VISUAL_INFRA_MAX_TICKS — retrying"
        [ -n "$verdict_file" ] && printf 'retry' > "$verdict_file"
        exit 3
      fi
    fi
  fi

  # ── Smoke gate CLASSIFICATION (charter #993) ──────────────────────────────
  # Consume smoke_rc ONLY here (post-cleanup), mirroring the visual-gate sibling
  # block above. NEVER a silent pass on infra.
  if [ "$smoke_rc" -eq 1 ]; then
    # Real FAIL (artifact proven broken). Flow through the SAME single-counter
    # N-confirmation + cache path as engine RED (~line 506/548) by setting
    # suite_rc=1 and appending SMOKE_REASON to the shared reason file.
    suite_rc=1
    printf 'SMOKE_REASON: %s\n' "${smoke_reason:-unknown}"
    printf 'smoke:%s\n' "${smoke_reason:-unknown}" >> "$_reason_file"
  elif [ "$smoke_rc" -eq 2 ] || [ "$smoke_rc" -eq 3 ]; then
    # INFRA (port/network/rate-limit/self-error). Mirror the visual-gate
    # infra-tick pattern: bump a counter, ceiling -> blocked/exit 1, else
    # retry/exit 3. NEVER a silent pass.
    local SMOKE_INFRA_MAX_TICKS=5
    local _smoke_infra_file="" smoke_infra_error_ticks=0
    [ -n "$_cache_file" ] && _smoke_infra_file="${_cache_file}.smoke_infra_ticks"
    [ -n "$_smoke_infra_file" ] && [ -f "$_smoke_infra_file" ] && \
      smoke_infra_error_ticks="$(cat "$_smoke_infra_file" 2>/dev/null || echo 0)"
    smoke_infra_error_ticks=$((smoke_infra_error_ticks + 1))
    [ -n "$_smoke_infra_file" ] && printf '%s' "$smoke_infra_error_ticks" > "$_smoke_infra_file"
    local _smoke_leaf_id; _smoke_leaf_id=$(printf '%s' "$branch" | grep -oE 'leaf/([0-9]+)' | grep -oE '[0-9]+' | head -1 || echo "")
    if [ "$smoke_infra_error_ticks" -ge "$SMOKE_INFRA_MAX_TICKS" ]; then
      local _smoke_blocked_msg="Smoke gate infra unavailable for ${smoke_infra_error_ticks} ticks (smoke_rc=${smoke_rc}). Manual intervention required."
      log "verify-merged: $_smoke_blocked_msg"
      if [ -n "$_smoke_leaf_id" ] && [ -n "${repo:-}" ]; then
        gh issue comment "$_smoke_leaf_id" -R "$repo" --body "$_smoke_blocked_msg" 2>/dev/null || true
        gh issue edit "$_smoke_leaf_id" -R "$repo" --add-label "status:blocked" 2>/dev/null || true
      fi
      [ -n "$verdict_file" ] && printf 'infra' > "$verdict_file"
      exit 1
    else
      log "verify-merged: smoke gate infra error (smoke_rc=$smoke_rc), tick $smoke_infra_error_ticks/$SMOKE_INFRA_MAX_TICKS — retrying"
      [ -n "$verdict_file" ] && printf 'retry' > "$verdict_file"
      exit 3
    fi
  fi

  # 3. Classify + single-counter N-confirmation (issue #195 / I3 anti-poison).
  #    rc=0 → pass (cache now, reset red-counter).
  #    rc=1 → real-red: bump per-leaf red-counter (ONE source of truth, shared with
  #           L3 #196), keyed same as cache (${leaf_sha}_${base_sha}); <N → retryable
  #           (exit 3, NOT cached); >=N → confirmed terminal red (exit 1, cached fail).
  #    else → infra (exit 2, not cached).
  local _redcount_file="" _confirm_n="${CB_VERIFY_CONFIRM_N:-2}" _rn=0
  [ -n "$_cache_dir" ] && [ -n "$_leaf_sha" ] && _redcount_file="${_cache_dir}/${_leaf_sha}.redcount"

  if [ "$suite_rc" -eq 0 ]; then
    [ -n "$verdict_file" ] && printf 'pass' > "$verdict_file"
    [ -n "$_cache_file" ] && printf 'pass' > "$_cache_file"
    [ -n "$_redcount_file" ] && rm -f "$_redcount_file"
    log "verify-merged: PASS (engine green on merged tree)"
    exit 0
  elif [ "$suite_rc" -eq 1 ]; then
    [ -n "$_redcount_file" ] && [ -f "$_redcount_file" ] && _rn="$(cat "$_redcount_file" 2>/dev/null || echo 0)"
    _rn=$((_rn + 1))
    [ -n "$_redcount_file" ] && printf '%s' "$_rn" > "$_redcount_file"
    if [ "$_rn" -ge "$_confirm_n" ]; then
      [ -n "$verdict_file" ] && printf 'fail' > "$verdict_file"
      [ -n "$_cache_file" ] && printf 'fail' > "$_cache_file"
      local _reason; _reason="$(sort -u "$_reason_file" 2>/dev/null | paste -sd, - 2>/dev/null)"
      [ -n "$_cache_file" ] && printf '%s' "${_reason:-unknown}" > "${_cache_file}.reason"
      rm -f "$_reason_file" 2>/dev/null
      printf 'RED_REASON: %s\n' "${_reason:-unknown}"
      log "verify-merged: FAIL (engine RED confirmed ${_rn}/${_confirm_n} on merged tree; failing: ${_reason:-unknown})"
      exit 1
    fi
    [ -n "$verdict_file" ] && printf 'retry' > "$verdict_file"
    log "verify-merged: RETRY (engine RED ${_rn}/${_confirm_n} — not yet confirmed, retryable)"
    exit 3
  else
    [ -n "$verdict_file" ] && printf 'infra' > "$verdict_file"
    log "verify-merged: INFRA (timeout or harness error; suite_rc=$suite_rc)"
    exit 2
  fi
}

# ── subcommand: regen-persist ─────────────────────────────────────────────────
# regen-persist <charter-id> --remote URL [--repo OWNER/REPO]
#
# #206 Part A — the COMMIT-PRODUCING persist point for the manifest sha-lock.
# Called by the launcher charter-finale AFTER the full engine suite is green on
# charter/<C> (the tree that becomes canon) and BEFORE the charter->main PR is
# created. Clones charter/<C>, regenerates the sha-lock against that tree, and —
# only if a row actually drifted — commits and pushes the refreshed manifest to
# charter/<C>. The subsequent human charter->main merge then carries the
# regenerated manifest onto canon (main), so doctor's deploy-vs-manifest integrity
# property holds at the canon boundary.
#
# Why the finale, not a per-leaf push: pushing a regen commit to every leaf PR
# head re-triggers CI and RACES when sibling leaves integrate concurrently (the
# base moves under each leaf). The integrity guarantee is a property of MAIN, so
# the regen is persisted exactly once, at the charter->main boundary.
#
# Idempotent: a no-op (no commit, no push) when the manifest is already fresh —
# so it is safe to call every finale tick without churning charter/<C>.
#
# Exit: 0 = success (committed+pushed a refresh, OR clean no-op: already fresh /
#           manifest absent in fixtures).
#       2 = infra (clone / fetch / push failed) — caller should retry next tick
#           and NOT create the PR (canon would carry a stale manifest otherwise).
cmd_regen_persist() {
  local cid="${1:-}"; shift || true
  [ -n "$cid" ] || { log "regen-persist: missing charter id"; exit 2; }
  local remote="" repo="${CB_REPO:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote) remote="$2"; shift ;;
      --repo)   repo="$2"; shift ;;
    esac; shift
  done
  [ -n "$remote" ] || { log "regen-persist: --remote is required"; exit 2; }

  local branch="charter/$cid"
  local tmpdir; tmpdir="$(mktemp -d)"

  git clone -q "$remote" "$tmpdir" 2>/dev/null || {
    log "regen-persist #$cid: clone failed"; rm -rf "$tmpdir"; exit 2; }
  git -C "$tmpdir" config user.email "integrator@crewboss" 2>/dev/null
  git -C "$tmpdir" config user.name  "crewboss-integrator"  2>/dev/null
  git -C "$tmpdir" fetch -q origin "$branch" 2>/dev/null \
    && git -C "$tmpdir" checkout -q -B "$branch" FETCH_HEAD 2>/dev/null || {
    log "regen-persist #$cid: cannot checkout $branch"; rm -rf "$tmpdir"; exit 2; }

  # Regen against the checked-out charter/<C> tree.
  if [ -f "$tmpdir/reference/bin/regen-manifest.sh" ]; then
    ( cd "$tmpdir" && bash reference/bin/regen-manifest.sh ) >/dev/null 2>&1 || true
  fi

  # Idempotent: nothing drifted → clean no-op (no commit, no push).
  if git -C "$tmpdir" diff --quiet -- reference/runtime-manifest.tsv 2>/dev/null; then
    log "regen-persist #$cid: manifest already fresh — no-op"
    rm -rf "$tmpdir"; exit 0
  fi

  git -C "$tmpdir" add reference/runtime-manifest.tsv 2>/dev/null
  git -C "$tmpdir" commit -q \
    -m "chore(manifest): regen sha-lock at charter-#${cid} finale" 2>/dev/null || {
    log "regen-persist #$cid: commit failed"; rm -rf "$tmpdir"; exit 2; }

  if git -C "$tmpdir" push -q origin "$branch" 2>/dev/null; then
    log "regen-persist #$cid: pushed refreshed manifest to $branch"
    rm -rf "$tmpdir"; exit 0
  else
    log "regen-persist #$cid: push to $branch failed"
    rm -rf "$tmpdir"; exit 2
  fi
}

# ── dispatch ──────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    close-leaf)    shift; cmd_close_leaf "$@" ;;
    gate-charter)  shift; cmd_gate_charter "$@" ;;
    try-merge)     shift; cmd_try_merge "$@" ;;
    verify-merged) shift; cmd_verify_merged "$@" ;;
    regen-persist) shift; cmd_regen_persist "$@" ;;
    *)
      printf 'usage: %s {close-leaf|gate-charter|try-merge|verify-merged|regen-persist} ...\n' \
        "$(basename "$0")" >&2
      exit 64 ;;
  esac
fi
