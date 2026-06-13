#!/usr/bin/env bash
# crewboss-launcher-gh.sh — launcher loop driving the REAL GitHub board via board-gh.sh.
# Same state machine as the local-JSON launcher (5b), but canonical state lives in gh
# labels; run-state (pid/starttime/tries) stays launcher-local under run/state/<id>/ (§9).
# SPAWN is overridable ($CB_SPAWN) so the loop is testable with a stub against synthetic
# gh issues — no jail, no spend.
#
# Subcommands: reconcile | once | run
# Env: CB_REPO (req), CB_HOME, CB_SPAWN, CB_REWORK_SPAWN, CB_RETRY_CAP, CB_MAX_PARALLEL,
#      CB_LAUNCHER_ID, CB_GIT_REMOTE, CB_INTEGRATOR,
#      CB_HARNESS (optional local cmd for gate-charter; default = marker-grep only),
#      CB_GATE_REPO_DIR (repo dir for marker-grep; default = .),
#      CB_FINALE_CHECKS_TIMEOUT (seconds to wait for draft-PR CI; default 300),
#      CB_FINALE_CHECKS_POLL (seconds between gh pr checks polls; default 15)
set -uo pipefail
: "${CB_REPO:?set CB_REPO=owner/repo}"; export CB_REPO
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"; STATE="$RUN/state"; LOCK="$RUN/launcher.lock"
RETRY_CAP="${CB_RETRY_CAP:-2}"; MAXP="${CB_MAX_PARALLEL:-2}"
LID="${CB_LAUNCHER_ID:-cb1}"
BOARD="$CB_HOME/board-gh.sh"
SPAWN="${CB_SPAWN:-$CB_HOME/crewboss-prep-spawn-gh.sh}"
# CB_PLAN_SPAWN: separate spawn for planning/tech-lead (default: same as CB_SPAWN so existing
# setups that only set CB_SPAWN keep working; run-charter.sh sets both explicitly).
PLAN_SPAWN="${CB_PLAN_SPAWN:-$SPAWN}"
CHARTER_SCOPE="${CREWBOSS_CHARTER:-0}"
# CB_REWORK_SPAWN: script used to re-dispatch a leaf that failed with a merge conflict
# (needs-rework state). Defaults to rework-prep.sh next to the launcher.
HERE_LAUNCHER="$(cd "$(dirname "$0")" && pwd)"
REWORK_SPAWN="${CB_REWORK_SPAWN:-$HERE_LAUNCHER/rework-prep.sh}"
GIT_REMOTE="${CB_GIT_REMOTE:-}"
INTEGRATOR_SCRIPT="${CB_INTEGRATOR:-$HERE_LAUNCHER/crewboss-integrator.sh}"
mkdir -p "$STATE"
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
log(){ echo "[launcher-gh $(now)] $*"; }
sget(){ cat "$STATE/$1/$2" 2>/dev/null || echo ""; }
sset(){ mkdir -p "$STATE/$1"; printf '%s' "$3" > "$STATE/$1/$2"; }
# ── CB_MANIFEST: optional team manifest directory ────────────────────────────
# When CB_MANIFEST is set:
#   1. Locate and source reference/launcher/manifest.sh (accessor library).
#      Search order: CB_MANIFEST_LIB (test override) →
#                    $HERE_LAUNCHER/../launcher/manifest.sh (repo checkout) →
#                    $CB_HOME/manifest.sh (box deploy).
#   2. manifest_validate "$CB_MANIFEST" — non-zero → log + exit 65 (fail-fast,
#      before any flock/board/loop activity; no issue claimed).
#   3. success → log "manifest: $CB_MANIFEST ok"; export CB_MANIFEST so child
#      spawns and board-gh inherit it.
# Without CB_MANIFEST: block is a no-op (legacy behaviour unchanged, byte-for-byte).
if [ -n "${CB_MANIFEST:-}" ]; then
  _mlib=""
  if [ -n "${CB_MANIFEST_LIB:-}" ]; then
    _mlib="$CB_MANIFEST_LIB"
  elif [ -f "$HERE_LAUNCHER/../launcher/manifest.sh" ]; then
    _mlib="$HERE_LAUNCHER/../launcher/manifest.sh"
  elif [ -f "$CB_HOME/manifest.sh" ]; then
    _mlib="$CB_HOME/manifest.sh"
  fi
  if [ -z "$_mlib" ] || [ ! -f "$_mlib" ]; then
    log "CB_MANIFEST=$CB_MANIFEST but manifest library not found (set CB_MANIFEST_LIB or deploy manifest.sh to $CB_HOME/)"
    exit 65
  fi
  # shellcheck source=../launcher/manifest.sh
  source "$_mlib"
  if ! manifest_validate "$CB_MANIFEST" >/dev/null 2>&1; then
    log "manifest invalid: $CB_MANIFEST"
    exit 65
  fi
  log "manifest: $CB_MANIFEST ok"
  export CB_MANIFEST
fi
board(){ bash "$BOARD" "$@"; }
# plannable_scoped: when CREWBOSS_CHARTER is set, restrict plannable output to that charter only.
plannable_scoped(){
  if [ "${CHARTER_SCOPE:-0}" = "0" ]; then
    board plannable
  else
    board plannable | grep "^${CHARTER_SCOPE}$" || true
  fi
}

# review-leaves scoped to the current charter scope.
# When CREWBOSS_CHARTER is set, filters to leaves of that charter (one gh-get per leaf).
# When unset (CHARTER_SCOPE=0), returns all review-leaves unscoped — safe fallback.
_review_leaves_scoped(){
  if [ "${CHARTER_SCOPE:-0}" = "0" ]; then
    board review-leaves 2>/dev/null || true
  else
    local _all _rid _c
    _all=$(board review-leaves 2>/dev/null || true)
    for _rid in $_all; do
      _c=$(board get "$_rid" charter 2>/dev/null || echo "$CHARTER_SCOPE")
      [ "$_c" = "$CHARTER_SCOPE" ] && echo "$_rid"
    done
  fi
}

# _finale_in_progress: returns 0 (true) if any charter has a draft PR with pending CI
# and the deadline has not yet expired.  Called by _loop_is_alive to prevent premature
# idle-exit while the non-blocking finale poll cycle is still working. [F4 #118]
_finale_in_progress(){
  local _d _cid _ci_state _pr_ts _now _timeout
  _timeout="${CB_FINALE_CHECKS_TIMEOUT:-300}"
  _now=$(date +%s)
  for _d in "$STATE"/finale-*/; do
    [ -d "$_d" ] || continue
    _cid="${_d%/}"; _cid="${_cid##*finale-}"
    # Scope filter (CHARTER_SCOPE=0 means no filter)
    [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$_cid" = "$CHARTER_SCOPE" ] || continue
    _ci_state=$(cat "$_d/ci_state" 2>/dev/null || echo "pending")
    [ "$_ci_state" = "pending" ] || continue
    _pr_ts=$(cat "$_d/pr_ts" 2>/dev/null || echo "")
    [ -n "$_pr_ts" ] || continue
    # Deadline not yet expired → this charter's finale is still in progress
    if [ "$_now" -lt $(( _pr_ts + _timeout )) ]; then
      return 0
    fi
  done
  return 1
}

# _loop_is_alive: liveness predicate for the run loop.
# Returns 0 (alive) when there is still pending work:
#   running > 0  — spawns in flight
#   fresh   > 0  — unhandled launchable/plannable work
#   review-leaves non-empty — leaves waiting for integrator merge
#   finale-in-progress — draft PR created, CI pending, deadline not expired [F4 #118]
_loop_is_alive(){   # args: running fresh → exit 0 = alive, exit 1 = idle
  local _running="$1" _fresh="$2"
  [ "$_running" -gt 0 ] && return 0
  [ "$_fresh"   -gt 0 ] && return 0
  [ -n "$(_review_leaves_scoped | head -1)" ] && return 0
  # finale-in-progress: draft PR created, CI pending, deadline not expired [F4 #118]
  _finale_in_progress && return 0
  return 1
}

reconcile(){
  local d id pid
  for d in "$STATE"/*/; do [ -e "$d" ] || continue
    id=$(basename "$d"); pid=$(sget "$id" pid); [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      log "reconcile: #$id alive (pid $pid)"
    else
      log "reconcile: #$id orphaned (pid '$pid' dead) -> requeue"
      board route "$id" requeue >/dev/null; sset "$id" pid ""
    fi
  done
}

route(){ # id, spawn-exit
  local id="$1" ex="$2" tries
  case "$ex" in
    0) board route "$id" review >/dev/null; sset "$id" pid ""; log "#$id -> review" ;;
    3) board route "$id" requeue >/dev/null; sset "$id" pid ""; log "#$id budget hard-stop -> requeued, STOPPING cycle"; return 9 ;;
    *) local prev; prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
       if [ "$tries" -ge "$RETRY_CAP" ]; then
         board route "$id" blocked "executor failed $tries× (retry-cap $RETRY_CAP) — tech-lead triage" >/dev/null
         sset "$id" pid ""; log "#$id failed (try $tries) -> blocked"
       else
         board route "$id" requeue >/dev/null; sset "$id" pid ""; log "#$id failed (try $tries) -> requeued"
       fi ;;
  esac
  return 0
}

claim_and_spawn(){ # id
  local id="$1" role spawn_cmd old_branch=""
  role=$(board get "$id" role)
  # Choose spawn path before claiming: needs-rework -> rework script, otherwise normal.
  if [ "$(board get "$id" state)" = "needs-rework" ]; then
    spawn_cmd="$REWORK_SPAWN"
    old_branch="$(sget "$id" pr_head)"
    log "claim #$id state=needs-rework -> rework path (old=${old_branch:-none})"
  else
    spawn_cmd="$SPAWN"
  fi
  board claim "$id" "$LID" >/dev/null   # also strips status:needs-rework (lifecycle)
  sset "$id" pid "$$"; sset "$id" starttime "$(now)"
  log "claim #$id role=$role (pid $$)"
  CB_OLD_BRANCH="$old_branch" "$spawn_cmd" "$id" "$role"; local ex=$?
  route "$id" "$ex"
}

# ── CI classifier ────────────────────────────────────────────────────────────
# _classify_ci <rollup_json_array>
# Normalises both CheckRun (.status/.conclusion) and StatusContext (.state) nodes.
# Returns: "success" | "failure" | "pending"
# SUCCESS of either type = success; FAILURE/ERROR = failure; everything else = pending.
_classify_ci(){
  local arr="$1"
  printf '%s' "$arr" | jq -r '
    [ .[] |
      if .state != null then
        # StatusContext node: use .state (SUCCESS / FAILURE / ERROR / PENDING / …)
        if   .state == "SUCCESS"                               then "success"
        elif (.state == "FAILURE" or .state == "ERROR")       then "failure"
        else "pending" end
      else
        # CheckRun node: use .status / .conclusion
        if .status == "COMPLETED" then
          if   (.conclusion == "SUCCESS" or .conclusion == "SKIPPED") then "success"
          elif (.conclusion == "FAILURE" or .conclusion == "ERROR"
               or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") then "failure"
          else "pending" end
        else "pending" end
      end
    ] |
    if   (map(select(. == "failure")) | length) > 0 then "failure"
    elif (map(select(. == "pending")) | length) > 0 then "pending"
    else "success" end
  ' 2>/dev/null || echo "pending"
}

# ── integrator cycle: merge review-state leaf PRs into charter/C ─────────────
# Called every tick of cmd_run after finished-spawn routing.
# GREEN-BEFORE-MERGE: CI (statusCheckRollup) must be success before any merge.
# Idempotent: merged/closed leaves not re-processed.  All errors logged, non-fatal.
_integrator_cycle(){
  if [ -z "$GIT_REMOTE" ]; then
    [ -n "${_REMOTE_DISABLED_LOGGED:-}" ] || log "integrator+finale DISABLED: CB_GIT_REMOTE not set"
    export _REMOTE_DISABLED_LOGGED=1
    return 0
  fi
  [ -x "$INTEGRATOR_SCRIPT" ] || { log "integrator: script not found: $INTEGRATOR_SCRIPT"; return 0; }

  local review_ids
  review_ids=$(board review-leaves 2>/dev/null || true)
  [ -n "$review_ids" ] || return 0

  local open_prs="" merged_prs="" rid pr_entry pr_head pr_num pr_base ci_raw ci_rc rollup_arr ci_status conflict_files try_exit
  local merge_sha="" file_list="" merge_rc=0 close_rc=0 pr_state="" rec_num="" rec_sha_r="" rec_rc=0

  # Snapshot open PRs once per cycle; match leaves by headRefName prefix leaf/<rid>- OR rework/<rid>-
  open_prs=$(gh pr list -R "$CB_REPO" --state open \
             --json number,headRefName,baseRefName 2>/dev/null || true)
  # Snapshot merged PRs once per cycle — needed for reconcile after a mid-run restart
  # (leaf stays in status:review but PR is already merged; no open PR exists).
  merged_prs=$(gh pr list -R "$CB_REPO" --state merged \
               --json number,headRefName,baseRefName 2>/dev/null || true)

  for rid in $review_ids; do
    # Skip leaves already handled this run (merged or blocked for no-CI)
    local done; done=$(sget "$rid" int_done)
    [ -n "$done" ] && continue

    # Find the open PR: headRefName must start with leaf/$rid- OR rework/$rid-
    # AND base must be charter/*; when multiple matches, take the highest PR number (newest).
    pr_entry=$(printf '%s' "$open_prs" | jq -r --arg rid "$rid" '
      [.[] | select((.headRefName | startswith("leaf/\($rid)-")) or
                   (.headRefName | startswith("rework/\($rid)-")))
           | select(.baseRefName | startswith("charter/"))]
      | sort_by(.number) | last
      | if . then [(.number|tostring), .headRefName, .baseRefName] | join("\t") else "" end
      ' 2>/dev/null || true)
    pr_num=$(printf '%s' "$pr_entry" | cut -f1)
    pr_head=$(printf '%s' "$pr_entry" | cut -f2)
    pr_base=$(printf '%s' "$pr_entry" | cut -f3)

    if [ -z "$pr_num" ]; then
      # No open PR — first reconcile: maybe already MERGED (leaf survived a launcher restart
      # mid-run, or close-leaf failed on a previous tick after a successful merge). [F5 #111]
      rec_num=$(printf '%s' "$merged_prs" | jq -r --arg rid "$rid" \
        '.[] | select(.headRefName | startswith("leaf/\($rid)-"))
             | select(.baseRefName | startswith("charter/"))
             | .number' 2>/dev/null | head -1 || true)
      if [ -n "$rec_num" ]; then
        log "integrator: #$rid in review with already-MERGED PR #$rec_num — reconcile close-leaf"
        rec_sha_r=$(gh pr view "$rec_num" -R "$CB_REPO" --json mergeCommit \
                   2>/dev/null | jq -r '.mergeCommit.oid // empty' 2>/dev/null) || rec_sha_r=""
        rec_rc=0
        bash "$INTEGRATOR_SCRIPT" close-leaf "$rid" \
             ${rec_sha_r:+--merge-sha "$rec_sha_r"} \
             --repo "$CB_REPO" 2>/dev/null || rec_rc=$?
        if [ "$rec_rc" -eq 0 ]; then
          sset "$rid" int_done "merged"
          log "integrator: #$rid reconcile-closed (sha: ${rec_sha_r:-n/a})"
        else
          log "integrator: #$rid reconcile close-leaf FAILED (rc=$rec_rc) — retry next tick"
        fi
        continue
      fi
      # int_done=merged but merged PR not visible yet (gh lag) — reconcile pending, not stale. [#113↔#111 seam]
      if [ "$(sget "$rid" int_done)" = "merged" ]; then
        log "integrator: #$rid in review, int_done=merged (reconcile pending close) — skip"
        continue
      fi
      # stale-guard: count consecutive ticks without an open PR.
      # After CB_REVIEW_STALE_TICKS ticks → route blocked (anti-livelock). [F1 #113]
      local _stale_prev _stale_next _stale_cap
      _stale_prev=$(sget "$rid" stale_ticks); _stale_prev=${_stale_prev:-0}
      _stale_cap="${CB_REVIEW_STALE_TICKS:-10}"
      _stale_next=$((_stale_prev + 1))
      sset "$rid" stale_ticks "$_stale_next"
      if [ "$_stale_next" -ge "$_stale_cap" ]; then
        log "integrator: #$rid review-stale (${_stale_next} ticks without open PR) — blocking"
        # Direct review→blocked: remove status:review AND add status:blocked so board
        # review-leaves no longer reports this leaf and _loop_is_alive can exit cleanly.
        gh issue edit "$rid" -R "$CB_REPO" \
          --remove-label status:review --add-label status:blocked 2>/dev/null || true
        gh issue comment "$rid" -R "$CB_REPO" \
          --body "review-stale: this leaf has been in status:review for ${_stale_next} ticks without an open PR. Routed to blocked for human triage." \
          2>/dev/null || true
      else
        log "integrator: #$rid in review but no open PR — skip (stale ${_stale_next}/${_stale_cap})"
      fi
      continue
    fi
    # PR found: reset stale counter so transient lag does not accumulate
    sset "$rid" stale_ticks "0"
    case "$pr_base" in
      charter/[0-9]*)  ;;
      *) log "integrator: #$rid PR #$pr_num base='$pr_base' not charter/* — skip"; continue ;;
    esac

    # ── GREEN-BEFORE-MERGE: CI must be success ────────────────────────────────
    # (a) Distinguish infra error from real empty rollup.
    # (b) Normalise both CheckRun and StatusContext nodes via _classify_ci.
    # (c) Empty rollup: apply no-CI policy with per-leaf tick counter.
    ci_rc=0
    ci_raw=$(gh pr view "$pr_num" -R "$CB_REPO" --json statusCheckRollup 2>/dev/null) || ci_rc=$?

    if [ "$ci_rc" -ne 0 ]; then
      # Infra error reading rollup — log and retry next tick; do NOT count as empty rollup.
      log "integrator: #$rid PR #$pr_num gh error reading CI rollup (exit $ci_rc) — retry next tick"
      continue
    fi

    rollup_arr=$(printf '%s' "$ci_raw" | jq -c '.statusCheckRollup // []' 2>/dev/null) || rollup_arr="[]"

    if [ "$rollup_arr" = "[]" ]; then
      # Empty rollup: apply no-CI policy (human decision required, per spec §p.2).
      # Counter is per-leaf in $STATE so it persists across ticks within a run.
      local empty_limit="${CB_CI_EMPTY_TICKS:-30}"
      local prev_empty; prev_empty=$(sget "$rid" ci_empty_ticks); prev_empty=${prev_empty:-0}
      local new_empty; new_empty=$((prev_empty + 1))
      sset "$rid" ci_empty_ticks "$new_empty"
      if [ "$new_empty" -ge "$empty_limit" ]; then
        log "integrator: #$rid PR #$pr_num empty CI rollup ${new_empty} ticks (≥${empty_limit}) — blocking, needs human"
        board route "$rid" blocked \
          "нет CI — на человека: PR #$pr_num имеет пустой CI rollup после ${new_empty} тиков. Добавьте CI или снимите метку blocked вручную." \
          >/dev/null || true
        sset "$rid" int_done "no-ci-blocked"
      else
        log "integrator: #$rid PR #$pr_num CI rollup пустой (тик ${new_empty}/${empty_limit}) — ожидание"
      fi
      continue
    fi

    # Real nodes present: reset empty counter and classify.
    sset "$rid" ci_empty_ticks "0"
    ci_status=$(_classify_ci "$rollup_arr")

    case "$ci_status" in
      pending)  log "integrator: #$rid PR #$pr_num CI pending — wait next tick"; continue ;;
      failure)  log "integrator: #$rid PR #$pr_num CI failed — not merging"; continue ;;
      success)  ;;
      *)        log "integrator: #$rid PR #$pr_num CI='$ci_status' unknown — skip"; continue ;;
    esac

    # ── try-merge dry-run ─────────────────────────────────────────────────────
    # Exit codes from crewboss-integrator.sh try-merge:
    #   0 = clean (safe to merge)
    #   1 = merge conflict (conflicting file paths on stdout)
    #   2 = infra error (clone/fetch/checkout failed — not a real conflict)
    try_exit=0
    conflict_files=$(bash "$INTEGRATOR_SCRIPT" try-merge "$pr_head" "$pr_base" \
                    --remote "$GIT_REMOTE" 2>/dev/null) || try_exit=$?

    if [ "$try_exit" -eq 2 ]; then
      # Infra error: keep leaf in review and retry next tick (no needs-rework). [F6 #112]
      log "integrator: #$rid PR #$pr_num try-merge infra error (exit 2) — keeping in review, retry next tick"
    elif [ "$try_exit" -eq 0 ]; then
      # Clean: merge PR → verify MERGED → close leaf → set int_done (all-or-nothing). [F5 #111]
      log "integrator: #$rid PR #$pr_num CI=green try-merge=clean — merging"
      merge_rc=0
      gh pr merge "$pr_num" -R "$CB_REPO" --merge 2>/dev/null || merge_rc=$?
      # Verify the PR is actually MERGED (guards against silent server-side rejections).
      pr_state=$(gh pr view "$pr_num" -R "$CB_REPO" --json state 2>/dev/null \
                 | jq -r '.state // empty' 2>/dev/null) || pr_state=""
      if [ "$merge_rc" -ne 0 ] || [ "$pr_state" != "MERGED" ]; then
        log "integrator: #$rid PR #$pr_num merge FAILED (rc=$merge_rc state=${pr_state:-?}) — not closing leaf; retry next tick"
        continue
      fi
      merge_sha=$(gh pr view "$pr_num" -R "$CB_REPO" --json mergeCommit \
                 2>/dev/null | jq -r '.mergeCommit.oid // empty' 2>/dev/null) || merge_sha=""
      close_rc=0
      bash "$INTEGRATOR_SCRIPT" close-leaf "$rid" \
           ${merge_sha:+--merge-sha "$merge_sha"} \
           --repo "$CB_REPO" 2>/dev/null || close_rc=$?
      if [ "$close_rc" -eq 0 ]; then
        sset "$rid" int_done "merged"
        log "integrator: #$rid closed (sha: ${merge_sha:-n/a})"
        # Close any other open PRs for this leaf superseded by the rework we just merged [F7 #115]
        local _sp_num
        for _sp_num in $(printf '%s' "$open_prs" | jq -r --arg rid "$rid" --arg merged "$pr_num" '
          .[] | select((.headRefName | startswith("leaf/\($rid)-")) or
                      (.headRefName | startswith("rework/\($rid)-")))
               | select(.baseRefName | startswith("charter/"))
               | select(.number | tostring != $merged)
               | .number' 2>/dev/null || true); do
          log "integrator: closing superseded PR #$_sp_num for leaf #$rid"
          gh pr comment "$_sp_num" -R "$CB_REPO" --body "superseded by rework" 2>/dev/null || true
          gh pr close "$_sp_num" -R "$CB_REPO" 2>/dev/null || true
        done
      else
        # Merge done but close failed: next tick finds PR in merged_prs and retries via reconcile. [F5 #111]
        log "integrator: #$rid close-leaf FAILED (rc=$close_rc) — int_done NOT set; retry next tick"
      fi
    else
      # Conflict (exit 1): route needs-rework so rework-spawn can rebase
      file_list=$(printf '%s' "$conflict_files" | head -5 | tr '\n' ' ' | sed 's/ *$//')
      [ -z "$file_list" ] && file_list="(unknown)"
      log "integrator: #$rid PR #$pr_num merge conflict: $file_list — needs-rework"
      # Persist the conflicting PR head so rework-spawn can pass it as CB_OLD_BRANCH
      sset "$rid" pr_head "$pr_head"
      board route "$rid" needs-rework "Merge conflict in: $file_list" >/dev/null || true
      # Clear terminal flag so rework-spawn can re-claim this leaf
      sset "$rid" term ""
    fi
  done
}

# ── charter finale: one non-blocking CI poll per tick ────────────────────────────
# Called by _charter_finale_cycle every tick for each charter with a draft PR.
# State is persisted in $STATE/finale-<cid>/ so the function is fast (no sleep).
# Return codes: 0=green (PR promoted), 1=red (CI failed), 2=timeout, 3=pending (come back).
# Dedup: posts a comment only on first transition into each terminal state. [F4 #118]
_finale_check_ci(){
  local cid="$1" pr_num="$2"
  local timeout="${CB_FINALE_CHECKS_TIMEOUT:-300}"
  local _fin_dir="$STATE/finale-$cid"
  mkdir -p "$_fin_dir"

  # Load persistent state.
  local ci_state pr_ts last_comment
  ci_state=$(cat "$_fin_dir/ci_state"     2>/dev/null || echo "pending")
  pr_ts=$(cat    "$_fin_dir/pr_ts"        2>/dev/null || echo "")
  last_comment=$(cat "$_fin_dir/last_comment" 2>/dev/null || echo "")

  # Initialise deadline clock on first call (after PR creation — anti-deadlock safe).
  if [ -z "$pr_ts" ]; then
    pr_ts=$(date +%s)
    printf '%s' "$pr_ts" > "$_fin_dir/pr_ts"
  fi

  # Already terminal? Return cached result with no new gh call.
  case "$ci_state" in
    green)   return 0 ;;
    red)     return 1 ;;
    timeout) return 2 ;;
  esac

  # ONE poll this tick (no sleep, no inner loop).
  local checks_out checks_rc=0
  checks_out=$(gh pr checks "$pr_num" -R "$CB_REPO" 2>&1) || checks_rc=$?

  local new_state
  if [ "$checks_rc" -eq 0 ]; then
    new_state="green"
  elif ! printf '%s' "$checks_out" | grep -qi "pending\|in.progress\|queued"; then
    new_state="red"
  elif [ "$(date +%s)" -ge $(( pr_ts + timeout )) ]; then
    new_state="timeout"
  else
    # Still pending, deadline not expired. Come back next tick.
    return 3
  fi

  # Persist new terminal state.
  printf '%s' "$new_state" > "$_fin_dir/ci_state"

  # Actions + dedup comment (one comment per state).
  case "$new_state" in
    green)
      log "charter-finale: #$cid PR #$pr_num CI green → promoting to ready"
      gh pr ready "$pr_num" -R "$CB_REPO" 2>/dev/null || true
      if [ "$last_comment" != "green" ]; then
        gh issue comment "$cid" -R "$CB_REPO" \
          --body "charter-finale: PR #$pr_num (charter/$cid → main) CI green — ready for human review" \
          2>/dev/null || true
        printf '%s' "green" > "$_fin_dir/last_comment"
      fi
      return 0 ;;
    red)
      log "charter-finale: #$cid PR #$pr_num CI failed — stays draft"
      if [ "$last_comment" != "red" ]; then
        gh issue comment "$cid" -R "$CB_REPO" \
          --body "charter-finale: PR #$pr_num (charter/$cid → main) CI failed — stays draft" \
          2>/dev/null || true
        printf '%s' "red" > "$_fin_dir/last_comment"
      fi
      return 1 ;;
    timeout)
      log "charter-finale: #$cid PR #$pr_num CI check timeout (${timeout}s) — stays draft"
      if [ "$last_comment" != "timeout" ]; then
        gh issue comment "$cid" -R "$CB_REPO" \
          --body "charter-finale: PR #$pr_num (charter/$cid → main) CI check timeout — stays draft" \
          2>/dev/null || true
        printf '%s' "timeout" > "$_fin_dir/last_comment"
      fi
      return 2 ;;
  esac
}

# ── charter finale cycle ──────────────────────────────────────────────────────
# Called every tick of cmd_run after _integrator_cycle.
# For each OPEN charter C where ALL leaves (Charter: #C issues) are CLOSED and
# charter/C exists ahead of main:
#   1. Run LOCAL gate BEFORE creating PR (marker-grep mandatory; CB_HARNESS optional).
#      MUST NOT read CI checks at this stage (PR doesn't exist yet — anti-deadlock).
#   2. Gate green → open draft PR charter/C → main.
#   3. Wait for CI checks on draft PR (gh pr checks with timeout).
#   4. CI green → promote (gh pr ready) + comment; CI red/timeout → stays draft + comment.
# Idempotent: existing open PR is re-checked, not duplicated.
# Charter stays OPEN — only a human (tech-lead) merges and closes it.
_charter_finale_cycle(){
  [ -n "$GIT_REMOTE" ] || return 0   # silence: already logged by _integrator_cycle
  [ -x "$INTEGRATOR_SCRIPT" ] || { log "charter-finale: integrator not found: $INTEGRATOR_SCRIPT"; return 0; }

  # Snapshot the board (single gh call)
  local all_issues
  all_issues=$(gh issue list -R "$CB_REPO" --state all -L 200 \
               --json number,state,labels,body 2>/dev/null) || all_issues="[]"

  # Iterate over OPEN charters
  local cid
  for cid in $(printf '%s' "$all_issues" | jq -r '
    .[] | select(.state == "OPEN")
       | select([.labels[].name] | index("type:charter") != null)
       | .number' 2>/dev/null); do
    [ -n "$cid" ] || continue
    # scope: skip charters not matching CREWBOSS_CHARTER (scope=0 means no filter)
    [ "$CHARTER_SCOPE" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue

    # Condition: ALL leaves (non-charter issues mentioning Charter: #C) are CLOSED
    local open_leaf_count
    open_leaf_count=$(printf '%s' "$all_issues" | jq -r --argjson c "$cid" '
      [ .[] | select(.state == "OPEN")
             | select(([.labels[].name] | any(. == "type:charter")) | not)
             | select((.body // "") | test("(?i)Charter:\\s*#?" + ($c|tostring)))
      ] | length' 2>/dev/null) || open_leaf_count=1
    [ "$open_leaf_count" = "0" ] || continue

    # Condition: charter/C branch exists on the remote and is strictly ahead of main
    # (main must be an ancestor of charter/C — stale/diverged branches are rejected)
    local branch="charter/$cid"
    git ls-remote --exit-code --heads "$GIT_REMOTE" "$branch" >/dev/null 2>&1 || continue
    local b_sha m_sha
    b_sha=$(git ls-remote "$GIT_REMOTE" "refs/heads/$branch" 2>/dev/null | awk '{print $1}' | head -1)
    m_sha=$(git ls-remote "$GIT_REMOTE" "refs/heads/main"    2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$b_sha" ] && [ "$b_sha" != "$m_sha" ] || continue
    # Ancestor check via temporary bare clone: main must be an ancestor of charter/C.
    # A charter behind or diverged from main fails this check and is skipped.
    local _anc_tmp _anc_rc
    _anc_tmp=$(mktemp -d)
    git clone -q --bare "$GIT_REMOTE" "$_anc_tmp/repo" 2>/dev/null \
      || { rm -rf "$_anc_tmp"; continue; }
    _anc_rc=0
    git -C "$_anc_tmp/repo" merge-base --is-ancestor \
      "main" "$branch" 2>/dev/null || _anc_rc=$?
    rm -rf "$_anc_tmp"
    [ "$_anc_rc" = "0" ] || continue  # main not ancestor of charter/C → stale/diverged

    # Idempotent: check for an existing open PR charter/C → main
    local existing_pr
    existing_pr=$(gh pr list -R "$CB_REPO" --head "$branch" --base main --state open \
                  --json number 2>/dev/null | jq -r '.[0].number // empty' 2>/dev/null) || existing_pr=""

    if [ -n "$existing_pr" ]; then
      log "charter-finale: #$cid existing PR #$existing_pr — re-checking CI"
      _finale_check_ci "$cid" "$existing_pr" || true
      continue
    fi

    # ── LOCAL GATE — runs BEFORE PR creation (anti-deadlock invariant) ────────
    local harness_args=()
    [ -n "${CB_HARNESS:-}" ] && harness_args=(--harness "$CB_HARNESS")
    # Location: --repo-dir is an explicit test/debug override; production uses
    # --remote so gate-charter clones the real charter branch tree and avoids
    # false-RED from CWD self-matches.
    local gate_loc_args=()
    if [ -n "${CB_GATE_REPO_DIR:-}" ]; then
      gate_loc_args=(--repo-dir "$CB_GATE_REPO_DIR")
    elif [ -n "$GIT_REMOTE" ]; then
      gate_loc_args=(--remote "$GIT_REMOTE")
    fi
    local gate_out gate_rc=0
    gate_out=$(bash "$INTEGRATOR_SCRIPT" gate-charter "$cid" \
                    "${harness_args[@]+"${harness_args[@]}"}" \
                    "${gate_loc_args[@]+"${gate_loc_args[@]}"}" 2>&1) || gate_rc=$?

    if [ "$gate_rc" -ne 0 ]; then
      log "charter-finale: #$cid local gate RED — PR not created"
      gh issue comment "$cid" -R "$CB_REPO" \
        --body "charter-finale gate RED (charter/$cid → main not created): $gate_out" \
        2>/dev/null || true
      continue
    fi

    log "charter-finale: #$cid gate green — creating draft PR $branch → main"

    # Create draft PR
    gh pr create -R "$CB_REPO" --draft --base main --head "$branch" \
      --title "Charter #$cid → main" \
      --body "Automated charter finale. Gate passed. Awaiting human review and merge." \
      2>/dev/null || true

    # Look up the newly created PR number
    local pr_num
    pr_num=$(gh pr list -R "$CB_REPO" --head "$branch" --base main --state open \
             --json number 2>/dev/null | jq -r '.[0].number // empty' 2>/dev/null) || pr_num=""

    if [ -z "$pr_num" ]; then
      log "charter-finale: #$cid PR create failed or not found"
      continue
    fi

    log "charter-finale: #$cid draft PR #$pr_num created — awaiting CI checks"
    # Initialise finale state so _finale_in_progress can track liveness from this tick.
    local _fin_dir="$STATE/finale-$cid"
    mkdir -p "$_fin_dir"
    printf '%s' "$pr_num"     > "$_fin_dir/pr_num"
    printf '%s' "$(date +%s)" > "$_fin_dir/pr_ts"
    printf '%s' "pending"     > "$_fin_dir/ci_state"
    _finale_check_ci "$cid" "$pr_num" || true
  done
}

cmd_once(){
  ( flock -n 9 || { log "another launcher holds the lock — exit"; exit 1; }
    reconcile
    local ids id launched=0 rc
    ids=$(board launchable)
    for id in $ids; do
      [ "$launched" -ge "$MAXP" ] && { log "parallel cap reached"; break; }
      claim_and_spawn "$id"; rc=$?
      launched=$((launched+1))
      [ "$rc" = "9" ] && break
    done
    log "cycle done: launched=$launched"
  ) 9>"$LOCK"
}

# --- run: background-parallel poll-loop (§4.6) ---
# Backgrounds each spawn (up to CB_MAX_PARALLEL concurrent), routes by status.json when the
# spawn process finishes (not by a blocking exit code), reconciles orphans, exits when idle.
running_count(){ local d id pid n=0
  for d in "$STATE"/*/; do [ -e "$d" ] || continue; id=$(basename "$d"); pid=$(sget "$id" pid)
    [ -n "$pid" ] && [ "$pid" != PENDING ] && kill -0 "$pid" 2>/dev/null && n=$((n+1)); done
  echo "$n"; }
cmd_run(){
  ( flock -n 9 || { log "another launcher holds the lock — exit"; exit 1; }
    local poll="${CB_POLL:-2}" maxticks="${CB_MAX_TICKS:-120}" ticks=0 stop="" id pid ph prev tries running idle_ticks=0
    reconcile   # STARTUP ONLY: requeue orphans from a previous run/reboot. Inside the loop,
                # the launcher started its own spawns, so a dead pid = finished (route by
                # status.json) — NOT an orphan; running reconcile per-tick would requeue every
                # normally-finished spawn before route-finished could route it.
    while :; do
      # kill-switch: stop the loop now (running spawns finish on their own / next reconcile).
      # exit 42: kill-switch-blocked (machine-readable; hint: unkill to clear the flag).
      [ -f "$RUN/kill_switch" ] && { log "kill-switch present — run blocked (hint: unkill to clear $RUN/kill_switch)"; exit 42; }
      # route finished background spawns (by status.json phase; phase=unknown -> treat as crash/fail)
      for d in "$STATE"/*/; do [ -e "$d" ] || continue; id=$(basename "$d"); pid=$(sget "$id" pid)
        { [ -n "$pid" ] && [ "$pid" != PENDING ]; } || continue
        kill -0 "$pid" 2>/dev/null && continue          # still running
        # charter planning task (tech-lead): route by the charter's own label, not by review.
        if [ "$(sget "$id" kind)" = "charter" ]; then
          cst=$(board get "$id" state)
          if [ "$cst" = "plan-review" ] || [ "$cst" = "approved" ]; then sset "$id" term 1; log "#$id planned -> $cst"
          else prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then sset "$id" term 1; board route "$id" blocked "tech-lead failed to decompose ($tries×)" >/dev/null; log "#$id plan failed -> blocked"
            else log "#$id plan failed -> retry"; fi
          fi
          sset "$id" pid ""; continue
        fi
        ph=$(jq -r '.phase' "$RUN/work/$id/status.json" 2>/dev/null || echo unknown)
        case "$ph" in
          done)        board route "$id" review  >/dev/null; sset "$id" term 1; log "#$id done -> review" ;;
          budget-stop) board route "$id" requeue >/dev/null; stop=1; log "#$id budget -> requeue, STOP new claims" ;;
          *)           prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
                       if [ "$tries" -ge "$RETRY_CAP" ]; then board route "$id" blocked "executor failed $tries× (retry-cap $RETRY_CAP)" >/dev/null; sset "$id" term 1; log "#$id failed($tries) -> blocked"
                       else board route "$id" requeue >/dev/null; log "#$id failed($tries) -> requeue"; fi ;;
        esac
        sset "$id" pid ""
      done
      # integrator step: merge review-state leaves into charter/C (every tick, non-fatal)
      _integrator_cycle || log "integrator-cycle: error (continuing)"
      # charter finale step: for charters with all leaves closed, run local gate + draft PR
      _charter_finale_cycle || log "charter-finale-cycle: error (continuing)"
      running=$(running_count)
      # pause: keep managing in-flight spawns but claim NO new work until the flag is removed.
      if [ -f "$RUN/pause" ]; then
        log "paused — not claiming new (rm $RUN/pause to resume)"
      # claim new launchable up to the cap
      elif [ -z "$stop" ]; then
        # plan charters first: a needs-plan charter -> spawn a tech-lead to decompose it
        # (it sets the charter to plan-review itself; local pid guard prevents double-spawn).
        for cid in $(plannable_scoped); do
          [ "$running" -ge "$MAXP" ] && break
          [ -n "$(sget "$cid" pid)" ] && continue
          [ -n "$(sget "$cid" term)" ] && continue
          sset "$cid" kind charter; sset "$cid" starttime "$(now)"
          ( "$PLAN_SPAWN" "$cid" tech-lead >/dev/null 2>&1 ) & sset "$cid" pid "$!"
          running=$((running+1)); log "bg-spawn tech-lead for charter #$cid (running=$running/$MAXP)"
        done
        for id in $(board launchable); do
          [ "$running" -ge "$MAXP" ] && break
          # local authority over gh read-after-write lag: never re-handle an id that is
          # already in flight (pid set) or already terminal this run (term set), even if the
          # (laggy) gh list still reports it launchable.
          [ -n "$(sget "$id" pid)" ] && continue
          [ -n "$(sget "$id" term)" ] && continue
          # Choose spawn path before claiming (needs-rework -> rework script)
          _bg_spawn="$SPAWN"
          _bg_old_branch=""
          if [ "$(board get "$id" state)" = "needs-rework" ]; then
            _bg_spawn="$REWORK_SPAWN"
            _bg_old_branch="$(sget "$id" pr_head)"
          fi
          board claim "$id" "$LID" >/dev/null; sset "$id" starttime "$(now)"
          ( CB_OLD_BRANCH="$_bg_old_branch" "$_bg_spawn" "$id" "$(board get "$id" role)" >/dev/null 2>&1 ) & sset "$id" pid "$!"
          running=$((running+1)); log "bg-spawn #$id (running=$running/$MAXP)"
        done
      fi
      # idle? nothing running AND (stopped OR no FRESH launchable). "fresh" excludes ids the
      # laggy gh list may still report but we've already handled (pid set / term).
      local fresh=0 fid
      for fid in $(board launchable) $(plannable_scoped); do { [ -n "$(sget "$fid" pid)" ] || [ -n "$(sget "$fid" term)" ]; } || fresh=$((fresh+1)); done
      if [ "$running" -eq 0 ] && [ -n "$stop" ]; then log "stopped"; break; fi
      # idle-exit is DEBOUNCED: require CB_IDLE_CONFIRM consecutive empty ticks, so a transient
      # empty `board launchable` (gh read-after-write lag) doesn't end the run with work pending.
      # Liveness: review-leaves (waiting for integrator merge) also hold the loop alive.
      # Key: liveness is by ISSUE STATE (status:review label), NOT by open-PR list, so a
      # read-after-write lag on `gh pr list` (leaf done→review, PR not yet visible) cannot
      # cause a premature idle-exit. See _loop_is_alive for the extensible predicate.
      if _loop_is_alive "$running" "$fresh"; then
        idle_ticks=0
      else
        idle_ticks=$((idle_ticks+1))
        [ "$idle_ticks" -ge "${CB_IDLE_CONFIRM:-2}" ] && { log "idle — run complete"; break; }
      fi
      ticks=$((ticks+1)); [ "$ticks" -ge "$maxticks" ] && { log "max ticks ($maxticks) — stop"; break; }
      sleep "$poll"
    done
  ) 9>"$LOCK"
}

case "${1:-once}" in
  reconcile) ( flock -n 9 || { log locked; exit 1; }; reconcile ) 9>"$LOCK" ;;
  once) cmd_once ;;
  run)  cmd_run ;;
  *) echo "usage: $0 {once|run|reconcile}"; exit 64 ;;
esac
