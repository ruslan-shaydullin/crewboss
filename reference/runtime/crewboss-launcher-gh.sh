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
#      CB_FINALE_CHECKS_POLL (no longer used — CI decoupled from GHA; kept for back-compat),
#      CB_PLAN_CONVERGE_CAP (max plan-review rounds before human-decision; default CB_CONVERGE_CAP or 4),
#      CB_ACCEPT_CONVERGE_CAP (max acceptance-review rounds before human-decision; default CB_CONVERGE_CAP or 4)
set -uo pipefail
: "${CB_REPO:?set CB_REPO=owner/repo}"; export CB_REPO
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"; STATE="$RUN/state"; LOCK="$RUN/launcher.lock"
RETRY_CAP="${CB_RETRY_CAP:-2}"; MAXP="${CB_MAX_PARALLEL:-2}"
CB_RECOVERY_CAP="${CB_RECOVERY_CAP:-2}"
# CB_SPAWN_TIMEOUT — per-spawn wall-clock kill (#212 I4 hang-protection); default 1800s (<< nsjail 3600).
LID="${CB_LAUNCHER_ID:-cb1}"
BOARD="$CB_HOME/board-gh.sh"
SPAWN="${CB_SPAWN:-$CB_HOME/crewboss-prep-spawn-gh.sh}"
# CB_PLAN_SPAWN: separate spawn for planning/tech-lead (default: same as CB_SPAWN so existing
# setups that only set CB_SPAWN keep working; run-charter.sh sets both explicitly).
PLAN_SPAWN="${CB_PLAN_SPAWN:-$SPAWN}"
# CB_ANALYSIS_SPAWN: spawn script for the analysis role (default: same as PLAN_SPAWN).
ANALYSIS_SPAWN="${CB_ANALYSIS_SPAWN:-$PLAN_SPAWN}"
# CB_APPROVAL_SPAWN: spawn script for the approval role (default: same as PLAN_SPAWN).
APPROVAL_SPAWN="${CB_APPROVAL_SPAWN:-$PLAN_SPAWN}"
# CB_REVIEW_SPAWN: spawn script for the substance-review role (#334 convergence). Default = PLAN_SPAWN.
REVIEW_SPAWN="${CB_REVIEW_SPAWN:-$PLAN_SPAWN}"
# CB_PLAN_REVIEW_SPAWN: spawn script for the plan-review role (#382 plan-convergence). Default = PLAN_SPAWN.
PLAN_REVIEW_SPAWN="${CB_PLAN_REVIEW_SPAWN:-$PLAN_SPAWN}"
# CB_ACCEPT_REVIEW_SPAWN: spawn script for the acceptance-review role (#522 acceptance-convergence). Default = PLAN_REVIEW_SPAWN.
ACCEPT_REVIEW_SPAWN="${CB_ACCEPT_REVIEW_SPAWN:-$PLAN_REVIEW_SPAWN}"
# CB_CONFLICT_SPAWN: spawn script for the conflict-resolution role (git-resolver).
# Default: same as PLAN_SPAWN so existing setups that only set CB_SPAWN keep working.
CONFLICT_SPAWN="${CB_CONFLICT_SPAWN:-$PLAN_SPAWN}"
# CB_TRIAGE_SPAWN: spawn script for the triage role (#787 recovery-triage).
# BLOCKED intercept paths route executor-failed leaves to status:needs-triage
# and spawn this script to post a ## Triage (machine) verdict comment.
# The completion-detect handler reads the verdict and routes by class.
# Default: same as PLAN_SPAWN so existing setups that set CB_PLAN_SPAWN get triage automatically.
TRIAGE_SPAWN="${CB_TRIAGE_SPAWN:-$PLAN_SPAWN}"
CHARTER_SCOPE="${CREWBOSS_CHARTER:-0}"
# CB_REWORK_SPAWN: script used to re-dispatch a leaf that failed with a merge conflict
# (needs-rework state). Defaults to rework-prep.sh next to the launcher.
HERE_LAUNCHER="$(cd "$(dirname "$0")" && pwd)"
REWORK_SPAWN="${CB_REWORK_SPAWN:-$HERE_LAUNCHER/rework-prep.sh}"
GIT_REMOTE="${CB_GIT_REMOTE:-}"
INTEGRATOR_SCRIPT="${CB_INTEGRATOR:-$HERE_LAUNCHER/crewboss-integrator.sh}"
# ── recovery escalation (charter #1049) ──────────────────────────────────────
# NEW kind=recovery cross-TICK state machine: when the simple triage/rework route does
# not resolve a confirmed-RED leaf, escalate to a manager (recovery-lead) that posts a
# `## Recovery (machine)` plan; the launcher then executes that plan step-by-step.
# CB_RECOVERY_SPAWN: spawn script for the recovery-lead manager role. Default = PLAN_SPAWN
# so existing setups that only set CB_PLAN_SPAWN get recovery escalation for free.
RECOVERY_SPAWN="${CB_RECOVERY_SPAWN:-$PLAN_SPAWN}"
# CB_RECOVERY_LEAD_CAP: max recovery-lead escalations per leaf (NEW; default 1). Tracked
# via run-state recovery_lead_n. DISTINCT from CB_RECOVERY_CAP (charter-bounce counter).
CB_RECOVERY_LEAD_CAP="${CB_RECOVERY_LEAD_CAP:-1}"
# CB_RECOVERY_PARSE: parser for the manager's `## Recovery (machine)` plan block.
CB_RECOVERY_PARSE="${CB_RECOVERY_PARSE:-$HERE_LAUNCHER/recovery-parse.sh}"
mkdir -p "$STATE"
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
log(){ echo "[launcher-gh $(now)] $*"; }
sget(){ cat "$STATE/$1/$2" 2>/dev/null || echo ""; }
sset(){ mkdir -p "$STATE/$1"; printf '%s' "$3" > "$STATE/$1/$2"; }
# ── _cb_issue_list: scalable replacement for the invalid `--paginate` board flag ──
# `--paginate` is NOT a valid flag on the issue `list` subcommand (it exists only on
# `gh api`); #969 wired it into every board query, so live `gh` answered `unknown
# flag` → empty sets → the launcher saw 0 charters and idled. This fetches
# ALL matching issues via `gh api --paginate` over the REST issues endpoint, which
# follows Link headers to completion: it scales past 100/200/1000 with NO magic
# limit and terminates on its own (nothing hangs), at ~1 request per 100 issues
# (economical on rate-limit). The REST payload is normalized to the exact
# `gh issue list --json number,state,labels,body` shape so every downstream jq
# consumer is unchanged: drop pull requests (REST /issues mixes PRs in; `gh issue
# list` does not), upcase .state ("open"→"OPEN"), reduce labels to [{name}].
# $1 = state (all|open|closed, default all).
#
# ── Rate-limit reduction (charter #1004) ──────────────────────────────────────
# The crewboss loop exhausted GitHub's 5000/h primary REST limit: `_cb_issue_list`
# is hit ~20×/tick, each re-paginating >600 issues, with CB_POLL→~180 ticks/h.
# Two layers fix this without changing any downstream jq consumer:
#   (1) ONE-FETCH-PER-TICK CACHE. cmd_run primes a per-tick in-memory snapshot via
#       _cb_tick_cache_refresh(); _cb_issue_list then serves every call site (and the
#       per-charter/per-leaf board scans) from that snapshot — all|open|closed are
#       jq-filtered views of a single `all` fetch. Freshness-within-a-tick is fine;
#       point-of-mutation critical checks (claim/route guards) stay point-fresh by
#       querying `gh issue view`/`board` directly, never this cache.
#   (2) CONDITIONAL REQUESTS (option b — sort=updated, NOT created-sort first-page).
#       With the default sort=created,desc a label/state change on an OLDER issue
#       bumps updated_at but the row stays on a later page, so the page-1 ETag wrongly
#       304s and the launcher serves stale state (the api.py:367 failure that forced
#       dropping ETag there). Fetching sort=updated,direction=desc floats ANY touched
#       issue to the TOP of page 1, so a 304 on the page-1 If-None-Match provably means
#       the whole list is unchanged → reuse the cached snapshot at NO primary-RL cost
#       (GitHub does not bill 304s against the primary limit). Reuses the build_state()
#       header pattern from ui/server/crewboss-api.py.
#
# _CB_ISSUE_ETAG    : page-1 ETag from the last full (non-304) fetch.
# _CB_TICK_CACHE_ALL: cached `all` snapshot JSON (normalized gh-issue-list shape).
# _CB_TICK_CACHE_OK : non-empty once a snapshot has been primed this run.
_CB_ISSUE_ETAG="${_CB_ISSUE_ETAG:-}"
_CB_TICK_CACHE_ALL=""
_CB_TICK_CACHE_OK=""

# _cb_issue_fetch: the raw paginated fetch (no cache). sort=updated direction=desc so
# the page-1 ETag conditional in _cb_tick_cache_refresh is sound (see above). Follows
# Link headers to completion at ~1 request/100 issues; normalized to the exact
# `gh issue list --json number,state,labels,body` shape so consumers are unchanged.
# $1 = state (all|open|closed, default all).
# Fallback: if gh api --paginate produces no output (e.g. hermetic test stubs that
# only handle `gh issue list`), falls back to `gh issue list -L 1000` so the
# per-tick cache is primed correctly and integration-stub tests stay green.
_cb_issue_fetch(){
  local _state="${1:-all}"
  local _raw _result
  _raw="$(gh api --paginate -X GET "/repos/$CB_REPO/issues" \
      -f state="$_state" -f per_page=100 -f sort=updated -f direction=desc)"
  if [ -n "$_raw" ]; then
    _result="$(printf '%s' "$_raw" \
      | jq -s 'add // [] | map(select(has("pull_request")|not)
                | {number, state:(.state|ascii_upcase), labels:[.labels[]|{name}], body})' 2>/dev/null)"
  else
    # gh api --paginate returned nothing (test stub / no REST access): fall back
    # to gh issue list which the hermetic stubs handle.
    _result="$(gh issue list -R "$CB_REPO" --state "$_state" \
        --json number,state,labels,body -L 1000 \
      | jq 'map({number, state:(.state|ascii_upcase), labels:[.labels[]|{name}], body})')"
  fi
  printf '%s' "${_result:-[]}"
}

# _cb_issue_list: serve from the per-tick cache when primed (cmd_run), else fetch live
# (cmd_once / reconcile / startup, where no tick cache exists). all|open|closed are
# views of the single cached `all` snapshot — no extra REST cost per call site.
_cb_issue_list(){
  local _state="${1:-all}"
  if [ -n "$_CB_TICK_CACHE_OK" ]; then
    case "$_state" in
      open)   printf '%s' "$_CB_TICK_CACHE_ALL" | jq 'map(select(.state=="OPEN"))'   2>/dev/null ;;
      closed) printf '%s' "$_CB_TICK_CACHE_ALL" | jq 'map(select(.state=="CLOSED"))' 2>/dev/null ;;
      *)      printf '%s' "$_CB_TICK_CACHE_ALL" ;;
    esac
    return 0
  fi
  _cb_issue_fetch "$_state"
}

# _cb_tick_cache_refresh: prime/refresh the per-tick snapshot at the start of each
# cmd_run tick. Sends a conditional If-None-Match probe on page 1 (sort=updated):
#   * 304  → the whole list is provably unchanged → reuse the cached snapshot at no
#            primary-RL cost (only when we already hold a snapshot to reuse).
#   * else → store the fresh page-1 ETag and re-paginate the full `all` list.
# The probe uses --include to read response headers (build_state() pattern).
_cb_tick_cache_refresh(){
  local _probe _hdrs _status _new_etag _line
  local _cmd=(gh api --include -X GET "/repos/$CB_REPO/issues"
              -f state=all -f per_page=100 -f sort=updated -f direction=desc)
  [ -n "$_CB_ISSUE_ETAG" ] && _cmd+=( -H "If-None-Match: $_CB_ISSUE_ETAG" )
  _probe="$("${_cmd[@]}")" || _probe=""
  # Header block = everything up to the first blank line (CRLF or LF).
  _hdrs="$(printf '%s' "$_probe" | sed -n '1,/^[[:space:]]*$/p')"
  _status="$(printf '%s' "$_hdrs" | head -1)"
  if printf '%s' "$_status" | grep -q '304' \
     && [ -n "$_CB_TICK_CACHE_OK" ] \
     && [ -n "$_CB_TICK_CACHE_ALL" ] \
     && [ "$_CB_TICK_CACHE_ALL" != "[]" ]; then
    # Unchanged list — keep the cached snapshot (no full re-fetch, no primary-RL spend).
    return 0
  fi
  # Changed (or first prime / probe failed): capture the new page-1 ETag, re-paginate.
  _new_etag=""
  while IFS= read -r _line; do
    case "$(printf '%s' "$_line" | tr 'A-Z' 'a-z')" in
      etag:*) _new_etag="$(printf '%s' "$_line" | sed 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//;s/[[:space:]]*$//')"; break ;;
    esac
  done <<EOF
$_hdrs
EOF
  local _fetched
  _fetched="$(_cb_issue_fetch all)"
  # Strip surrounding whitespace to normalise the value before validity check.
  _fetched="$(printf '%s' "$_fetched" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$_fetched" ] || [ "$_fetched" = "[]" ] || [ "$_fetched" = "null" ]; then
    printf '%s\n' "tick-cache fetch empty/failed — forcing full refetch next tick"
    # Do NOT assign _CB_TICK_CACHE_ALL, do NOT set _CB_TICK_CACHE_OK=1,
    # do NOT update _CB_ISSUE_ETAG.  The missing/unchanged ETag ensures the
    # next tick sends no If-None-Match header → GitHub returns 200 → full re-paginate.
    return 0
  fi
  _CB_TICK_CACHE_ALL="$_fetched"
  _CB_TICK_CACHE_OK=1
  [ -n "$_new_etag" ] && _CB_ISSUE_ETAG="$_new_etag"
  return 0
}

# ── Rate-limit backoff guard (charter #1004) ─────────────────────────────────
# Query gh api /rate_limit `remaining`; below CB_RL_FLOOR, defer the gh-heavy tick by
# sleeping toward the hourly reset so the loop never drives the primary limit to 0
# (the #996 paralysis). Never fully stalls without real RL pressure: an unreadable or
# healthy `remaining` returns immediately. The wait is capped (CB_RL_BACKOFF_MAX) so a
# skewed reset clock cannot wedge the loop. No tokens are ever logged.
CB_RL_FLOOR="${CB_RL_FLOOR:-1000}"
_cb_rl_remaining(){ gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo ""; }
_cb_rl_backoff(){
  local _rl_remaining _reset _now _wait
  _rl_remaining="$(_cb_rl_remaining)"
  # Unreadable (no creds/network) → do not stall artificially (charter constraint).
  [ -n "$_rl_remaining" ] || return 0
  if [ "$_rl_remaining" -lt "$CB_RL_FLOOR" ] 2>/dev/null; then
    _reset="$(gh api /rate_limit -q '.resources.core.reset' 2>/dev/null || echo 0)"
    _now="$(date -u +%s)"
    _wait=$(( _reset - _now )); [ "$_wait" -lt 0 ] 2>/dev/null && _wait=0
    [ "$_wait" -gt "${CB_RL_BACKOFF_MAX:-60}" ] 2>/dev/null && _wait="${CB_RL_BACKOFF_MAX:-60}"
    log "rate-limit pressure: remaining=$_rl_remaining < floor=$CB_RL_FLOOR — deferring gh-heavy ops ${_wait}s"
    sleep "$_wait" 2>/dev/null || true
    return 1
  fi
  return 0
}
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
  # Graceful fallback: if the manifest directory doesn't exist (e.g., stale env var from a
  # previous install), clear CB_MANIFEST and proceed without manifest mode rather than blocking.
  if [ ! -d "$CB_MANIFEST" ]; then
    log "CB_MANIFEST=$CB_MANIFEST: directory not found, proceeding without manifest"
    CB_MANIFEST=""
  else
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
  # recovery-in-progress liveness (charter #1049): keep the loop alive while any leaf is
  # mid-recovery (kind=recovery, not yet terminal) so its cross-TICK plan can finish.
  local _rec_d _rec_id
  for _rec_d in "$STATE"/*/; do
    [ -e "$_rec_d" ] || continue
    _rec_id=$(basename "$_rec_d")
    [ "$(sget "$_rec_id" kind)" = "recovery" ] && [ -z "$(sget "$_rec_id" term)" ] && return 0
  done
  # manifest-pipeline liveness: keep alive while a charter is in needs-analysis,
  # or in team-review WITHOUT an open type:human-decision issue for it (N-1: over-threshold
  # escalation waits for a human outside the run; that charter does NOT hold the loop).
  if [ -n "${CB_MANIFEST:-}" ]; then
    local _all_issues _cid _cst _hd_open
    _all_issues=$(_cb_issue_list all 2>/dev/null || echo "[]")
    for _cid in $(printf '%s' "$_all_issues" | jq -r '
      .[] | select(.state=="OPEN")
           | select([.labels[].name] | index("type:charter") != null)
           | .number' 2>/dev/null); do
      [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$_cid" = "$CHARTER_SCOPE" ] || continue
      _cst=$(board get "$_cid" state 2>/dev/null || echo "")
      case "$_cst" in
        needs-analysis) return 0 ;;
        team-review)
          # Only holds the loop if there is NO open human-decision issue for this charter
          _hd_open=$(printf '%s' "$_all_issues" | jq -r --argjson c "$_cid" '
            [ .[] | select(.state=="OPEN")
                   | select([.labels[].name] | index("type:human-decision") != null)
                   | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))
            ] | length' 2>/dev/null || echo "0")
          [ "${_hd_open:-0}" = "0" ] && return 0
          ;;
      esac
    done
  fi
  return 1
}

reconcile(){
  local d id pid
  for d in "$STATE"/*/; do [ -e "$d" ] || continue
    id=$(basename "$d"); pid=$(sget "$id" pid); [ -n "$pid" ] || continue
    # kind=triage/recovery guard: these have their own completion handlers; do NOT requeue as
    # orphan. The completion-detect loop routes them when the agent/step finishes.
    if [ "$(sget "$id" kind)" = "triage" ] || [ "$(sget "$id" kind)" = "recovery" ]; then
      log "reconcile: #$id kind=$(sget "$id" kind) — skip (handled by completion-detect)"
      continue
    fi
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
         if [ -n "${TRIAGE_SPAWN:-}" ] && [ -z "$(sget "$id" triage_done)" ]; then
           board route "$id" needs-triage "executor failed $tries×" >/dev/null
           sset "$id" kind "triage"
           "$TRIAGE_SPAWN" "$id" &
           sset "$id" pid "$!"
           log "#$id failed (try $tries) -> needs-triage (triage spawned)"
         else
           board route "$id" blocked "executor failed $tries× (retry-cap $RETRY_CAP) — tech-lead triage" >/dev/null
           sset "$id" pid ""; log "#$id failed (try $tries) -> blocked"
         fi
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

# ── recovery escalation + cross-TICK plan executor (charter #1049) ────────────
# _recovery_escalate <id> <red_reason>
#   Manager escalation hook (component a). Routes the leaf to the NEW status:needs-recovery
#   label and spawns the recovery-lead manager INSTEAD of writing status:blocked.
#   (e) Graceful degradation: gated behind RED_REASON availability (charter #1110 — the
#       manager is blind without it, "ЗАВИСИТ от слоя 1"). With an empty reason this
#       returns 1 so the caller falls through to the current triage/blocked behaviour.
#   Bounded by CB_RECOVERY_LEAD_CAP (recovery_lead_n). Returns 0 when it escalated (the
#   caller MUST `continue`), 1 when it declined (caller falls through to blocked).
_recovery_escalate() {
  local _id="$1" _reason="${2:-}"
  [ -n "$_reason" ] || { log "#$_id recovery: no RED_REASON (manager blind, #1110) — falling through to blocked"; return 1; }
  local _rln; _rln=$(sget "$_id" recovery_lead_n); _rln=${_rln:-0}
  if [ "$_rln" -ge "$CB_RECOVERY_LEAD_CAP" ]; then
    log "#$_id recovery: lead-cap ($_rln/$CB_RECOVERY_LEAD_CAP) reached — falling through to blocked"
    return 1
  fi
  _rln=$((_rln + 1)); sset "$_id" recovery_lead_n "$_rln"
  sset "$_id" red_reason "$_reason"
  gh issue edit "$_id" -R "$CB_REPO" \
    --remove-label status:blocked \
    --remove-label status:review \
    --remove-label status:needs-rework \
    --remove-label status:needs-triage \
    --add-label status:needs-recovery >/dev/null 2>&1 || true
  # NEW kind=recovery state machine; fresh plan/cursor for this escalation.
  sset "$_id" kind recovery
  sset "$_id" recovery_plan ""
  sset "$_id" recovery_cursor ""
  sset "$_id" recovery_await ""
  sset "$_id" term ""
  sset "$_id" starttime "$(now)"
  ( "$RECOVERY_SPAWN" "$_id" recovery-lead >/dev/null 2>&1 ) & sset "$_id" pid "$!"
  log "#$_id recovery: escalated to recovery-lead ($_rln/$CB_RECOVERY_LEAD_CAP; reason: $_reason)"
  return 0
}

# _recovery_terminal <id> <why> [detail]
#   Component (d): terminal sink. NEVER status:blocked / human-halt — always status:deferred
#   plus an evidence comment, and clears recovery run-state.
_recovery_terminal() {
  local _id="$1" _why="$2" _detail="${3:-}"
  gh issue edit "$_id" -R "$CB_REPO" \
    --remove-label status:needs-recovery \
    --remove-label status:needs-rework \
    --remove-label status:review \
    --add-label status:deferred >/dev/null 2>&1 || true
  gh issue comment "$_id" -R "$CB_REPO" \
    --body "$(printf 'recovery: %s — routed status:deferred (never blocked). %s' "$_why" "$_detail")" >/dev/null 2>&1 || true
  sset "$_id" kind ""; sset "$_id" pid ""; sset "$_id" term 1; sset "$_id" recovery_await ""
  log "#$_id recovery: terminal ($_why) -> deferred"
}

# _recovery_reverify <id>  -> prints "GREEN" or "RED:<reason>"
#   Component (c) re-verify read: run verify-merged on the leaf's open PR (mirrors the
#   integrator). Gated behind RED_REASON availability via GIT_REMOTE (#1110/#176).
_recovery_reverify() {
  local _id="$1"
  [ -n "$GIT_REMOTE" ] || { printf 'RED:no-remote'; return 0; }
  local _pr_entry _ph _pb _vm_exit=0 _vm_out _reason
  _pr_entry=$(gh pr list -R "$CB_REPO" --state open --json number,headRefName,baseRefName 2>/dev/null \
    | jq -r --arg rid "$_id" '
        [.[] | select((.headRefName | startswith("leaf/\($rid)-")) or
                      (.headRefName | startswith("rework/\($rid)-")))
             | select(.baseRefName | startswith("charter/"))]
        | sort_by(.number) | last
        | if . then [.headRefName, .baseRefName] | join("\t") else "" end' 2>/dev/null || true)
  _ph=$(printf '%s' "$_pr_entry" | cut -f1); _pb=$(printf '%s' "$_pr_entry" | cut -f2)
  [ -n "$_ph" ] || { printf 'RED:no-pr'; return 0; }
  _vm_out=$(bash "$INTEGRATOR_SCRIPT" verify-merged "$_ph" "$_pb" \
            --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>/dev/null) || _vm_exit=$?
  _reason=$(printf '%s\n' "$_vm_out" | sed -n 's/^RED_REASON: //p' | head -1)
  if [ "$_vm_exit" -eq 0 ]; then printf 'GREEN'; else printf 'RED:%s' "${_reason:-engine-red}"; fi
}

# _recovery_dispatch_step <id>
#   Component (c): dispatch the step at recovery_cursor via existing label transitions, then
#   return control to the loop. Component (d): exhaustion -> deferred (never blocked).
_recovery_dispatch_step() {
  local _id="$1" _plan _cursor _len _row _route _terminal _ch
  _plan=$(sget "$_id" recovery_plan)
  _cursor=$(sget "$_id" recovery_cursor); _cursor=${_cursor:-0}
  _terminal=$(printf '%s\n' "$_plan" | awk -F'\t' '$1=="terminal"{print $2}')
  _len=$(printf '%s\n' "$_plan" | awk -F'\t' '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')
  # (d) cursor exceeds plan length (exhaustion) -> deferred.
  if [ "$_cursor" -ge "${_len:-0}" ]; then
    _recovery_terminal "$_id" "plan-exhausted" "all ${_len} recovery steps RED (terminal=${_terminal:-?})"
    return 0
  fi
  _row=$(printf '%s\n' "$_plan" | awk -F'\t' -v c="$_cursor" '$1==c{print; exit}')
  _route=$(printf '%s' "$_row" | awk -F'\t' '{print $4}')
  log "#$_id recovery: dispatch step $_cursor route=$_route (terminal=${_terminal:-?}, len=$_len)"
  case "$_route" in
    test-bug|executor-rework)
      # re-claim by an executor via the existing needs-rework dispatch path.
      gh issue edit "$_id" -R "$CB_REPO" \
        --remove-label status:needs-recovery --add-label status:needs-rework >/dev/null 2>&1 || true
      sset "$_id" recovery_await "$_cursor"; sset "$_id" term ""; sset "$_id" pid ""
      ;;
    needs-analysis)
      # bounce the parent charter to analysis (re-plan); the leaf hands off and is deferred.
      _ch=$(board get "$_id" charter 2>/dev/null || true)
      [ -n "$_ch" ] && gh issue edit "$_ch" -R "$CB_REPO" \
        --remove-label status:approved --add-label status:needs-analysis >/dev/null 2>&1 || true
      _recovery_terminal "$_id" "step-$_cursor-needs-analysis" "bounced charter #${_ch:-?} to analysis for re-plan"
      ;;
    *)
      log "#$_id recovery: step $_cursor unknown route '$_route' — advancing cursor"
      sset "$_id" recovery_cursor "$((_cursor + 1))"
      _recovery_dispatch_step "$_id"
      ;;
  esac
  return 0
}

# ── integrator cycle: merge review-state leaf PRs into charter/C ─────────────
# Called every tick of cmd_run after finished-spawn routing.
# GREEN-BEFORE-MERGE: verify-merged (engine suite on merged tree) must pass before merge.
# Idempotent: merged/closed leaves not re-processed.  All errors logged, non-fatal.
_integrator_cycle(){
  if [ -z "$GIT_REMOTE" ]; then
    [ -n "${_REMOTE_DISABLED_LOGGED:-}" ] || log "integrator+finale DISABLED: CB_GIT_REMOTE not set — verify-merged + rework/escalation trigger ALSO held (verify-red will NOT route leaves to needs-rework until a remote is set)"
    export _REMOTE_DISABLED_LOGGED=1
    return 0
  fi
  [ -x "$INTEGRATOR_SCRIPT" ] || { log "integrator: script not found: $INTEGRATOR_SCRIPT"; return 0; }

  local review_ids
  review_ids=$(board review-leaves 2>/dev/null || true)
  [ -n "$review_ids" ] || return 0

  local open_prs="" merged_prs="" rid pr_entry pr_head pr_num pr_base conflict_files try_exit
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
    # charter #1049: a leaf mid-recovery (kind=recovery) is owned by the recovery state
    # machine, which does its own verify/merge decision — the integrator must not double-
    # process it (would re-trigger rework/blocked escalation and fight the cursor).
    [ "$(sget "$rid" kind)" = "recovery" ] && continue

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

    # (c) Infra backoff: skip leaf until infra_next_retry_ts has elapsed (charter #350 / issue #918).
    local _inrt; _inrt=$(sget "$rid" infra_next_retry_ts)
    if [ -n "$_inrt" ] && [ "$(date +%s)" -lt "$_inrt" ]; then
      log "integrator: #$rid PR #$pr_num infra backoff active — next retry at ${_inrt}, skipping tick"
      continue
    fi

    # ── try-merge dry-run ─────────────────────────────────────────────────────
    # Exit codes from crewboss-integrator.sh try-merge:
    #   0 = clean (safe to merge)
    #   1 = merge conflict (conflicting file paths on stdout)
    #   2 = infra error (clone/fetch/checkout failed — not a real conflict)
    try_exit=0
    conflict_files=$(bash "$INTEGRATOR_SCRIPT" try-merge "$pr_head" "$pr_base" \
                    --remote "$GIT_REMOTE" 2>/dev/null) || try_exit=$?

    if [ "$try_exit" -eq 2 ]; then
      # Infra error: exponential backoff with file-backed persistent state (charter #350 / issue #918). [F6 #112]
      # (a) Load infra_attempt from disk (default 0 if absent); increment by 1; write back.
      local _ia; _ia=$(sget "$rid" infra_attempt); _ia=${_ia:-0}; _ia=$((_ia + 1))
      sset "$rid" infra_attempt "$_ia"
      # (b) Compute next_retry_ts = now + CB_INFRA_BACKOFF_BASE * CB_INFRA_BACKOFF_MULT^(attempt-1), cap exponent at 10.
      local _ib_delay _ib_power _ib_i
      _ib_delay="${CB_INFRA_BACKOFF_BASE:-60}"
      _ib_power=$((_ia - 1)); [ "$_ib_power" -gt 10 ] && _ib_power=10
      _ib_i=0
      while [ "$_ib_i" -lt "$_ib_power" ]; do
        _ib_delay=$((_ib_delay * ${CB_INFRA_BACKOFF_MULT:-2}))
        _ib_i=$((_ib_i + 1))
      done
      sset "$rid" infra_next_retry_ts "$(( $(date +%s) + _ib_delay ))"
      # (d) If infra_attempt >= CB_INFRA_RETRY_CAP: escalate to blocked.
      if [ "$_ia" -ge "${CB_INFRA_RETRY_CAP:-5}" ]; then
        log "integrator: #$rid PR #$pr_num try-merge infra error — cap (${_ia}/${CB_INFRA_RETRY_CAP:-5}) reached — escalating to blocked"
        gh issue comment "$rid" -R "$CB_REPO" \
          --body "try-merge infra retry cap reached (${_ia}/${CB_INFRA_RETRY_CAP:-5}) — escalated to blocked for human triage." \
          2>/dev/null || true
        gh issue edit "$rid" -R "$CB_REPO" \
          --remove-label status:review --add-label status:blocked 2>/dev/null || true
      else
        log "integrator: #$rid PR #$pr_num try-merge infra error (exit 2) — attempt ${_ia}/${CB_INFRA_RETRY_CAP:-5}, backoff ${_ib_delay}s, retry after infra_next_retry_ts"
      fi
    elif [ "$try_exit" -eq 0 ]; then
      # Clean merge: run verify-merged (engine suite on merged tree) before merging. [#176]
      local vm_exit=0
      local vm_out=""
      vm_out=$(bash "$INTEGRATOR_SCRIPT" verify-merged "$pr_head" "$pr_base" \
           --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>/dev/null) || vm_exit=$?
      local _vmreason; _vmreason="$(printf '%s\n' "$vm_out" | sed -n 's/^RED_REASON: //p' | head -1)"
      if [ "$vm_exit" -eq 1 ]; then
        # [#208] confirmed terminal RED → escalate; clear term + remove review EXPLICITLY (board route
        # does NOT remove status:review → busy-loop, latent #196 bug); carry the RED reason into the comment.
        local _rwk; _rwk=$(sget "$rid" rework_n); [ -n "$_rwk" ] || _rwk=0
        if [ "$_rwk" -ge "${CB_REWORK_CAP:-2}" ]; then
          log "integrator: #$rid PR #$pr_num verify-merged FAIL confirmed — rework-cap (${_rwk}/${CB_REWORK_CAP:-2}) reached → blocked (${_vmreason:-RED})"
          # Trigger path (a): triage intercept (#787) — spawn triage before writing status:blocked.
          _td=$(sget "$rid" triage_done 2>/dev/null || true)
          if [ -z "$_td" ]; then
            gh issue edit "$rid" -R "$CB_REPO" --remove-label status:review --add-label status:needs-triage >/dev/null 2>&1 || true
            sset "$rid" kind triage
            sset "$rid" red_reason "$_vmreason"   # carry RED_REASON so a no-verdict triage can escalate to recovery (#1049/#1110)
            sset "$rid" starttime "$(now)"
            ( "$TRIAGE_SPAWN" "$rid" triage >/dev/null 2>&1 ) & sset "$rid" pid "$!"
            sset "$rid" int_done "triage-pending"
            log "triage: spawned for #$rid (integrator path)"
            continue
          fi
          # triage_done is set: the simple route did not resolve and the rework-cap was hit a
          # SECOND time. charter #1049 (a): escalate to the recovery-lead (status:needs-recovery)
          # INSTEAD of status:blocked, gated behind RED_REASON availability (#1110). Falls
          # through to the blocked write only when the manager would be blind / lead-cap reached.
          if _recovery_escalate "$rid" "${_vmreason}"; then
            continue
          fi
          gh issue edit "$rid" -R "$CB_REPO" --remove-label status:review --add-label status:blocked >/dev/null 2>&1 || true
          gh issue comment "$rid" -R "$CB_REPO" --body "verify-merged confirmed engine RED after ${_rwk} reworks — failing: ${_vmreason:-engine RED}" >/dev/null 2>&1 || true
        else
          _rwk=$((_rwk + 1)); sset "$rid" rework_n "$_rwk"; sset "$rid" term ""
          log "integrator: #$rid PR #$pr_num verify-merged FAIL confirmed — escalating to needs-rework (rework ${_rwk}/${CB_REWORK_CAP:-2}; ${_vmreason:-RED})"
          gh issue edit "$rid" -R "$CB_REPO" --remove-label status:review --add-label status:needs-rework >/dev/null 2>&1 || true
          gh issue comment "$rid" -R "$CB_REPO" --body "verify-merged confirmed engine RED — failing: ${_vmreason:-engine RED on merged tree}" >/dev/null 2>&1 || true
        fi
        continue
      elif [ "$vm_exit" -eq 3 ]; then
        # Retryable RED (#195: red-counter < N, not yet confirmed).
        # CB_VERIFY_FLAKE_CAP: per-leaf ceiling on retryable-red retries; default 5.
        # Distinct from CB_RETRY_CAP (executor-spawn cap) — different semantic.
        # Tracks flake count in state dir keyed by leaf sha; once cap reached → defer.
        local _flake_cap _flake_n
        _flake_cap="${CB_VERIFY_FLAKE_CAP:-5}"
        _flake_n=$(sget "$rid" flake_n); _flake_n=${_flake_n:-0}
        _flake_n=$((_flake_n + 1))
        sset "$rid" flake_n "$_flake_n"
        if [ "$_flake_n" -ge "$_flake_cap" ]; then
          log "integrator: #$rid PR #$pr_num verify-merged flake-cap (${_flake_n}/${_flake_cap}) — deferring (#612)"
          gh issue edit "$rid" -R "$CB_REPO" \
            --remove-label status:review --add-label status:deferred 2>/dev/null || true
          gh issue comment "$rid" -R "$CB_REPO" \
            --body "verify-merged: retryable red exceeded flake cap (${_flake_n}/${_flake_cap} retries, CB_VERIFY_FLAKE_CAP) — deferred for human triage" \
            2>/dev/null || true
          sset "$rid" int_done "deferred"
        else
          log "integrator: #$rid PR #$pr_num verify-merged retryable red (exit 3, <N, flake ${_flake_n}/${_flake_cap}) — staying in review, retry next tick"
        fi
        continue
      elif [ "$vm_exit" -eq 2 ]; then
        # Infra error — log and retry next tick (same as try-merge infra). [F6]
        log "integrator: #$rid PR #$pr_num verify-merged infra error (exit 2) — retry next tick"
        continue
      fi
      # verify-merged PASS (exit 0): proceed to merge.
      # Clean: merge PR → verify MERGED → close leaf → set int_done (all-or-nothing). [F5 #111]
      log "integrator: #$rid PR #$pr_num verify-merged=pass try-merge=clean — merging"
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

# ── charter finale: non-blocking CI state resolution per tick ────────────────────
# Called by _charter_finale_cycle every tick for each charter with a draft PR.
# State is persisted in $STATE/finale-<cid>/ so the function is fast (no sleep).
# Return codes: 0=green (PR promoted/merged), 1=red/infra (gate failed), 2=timeout (cached).
# Dedup: posts a comment only on first transition into each terminal state. [F4 #118]
# GHA-CI gate removed (charter #685): verify-merged (box-native engine suite) gates
# auto-merge instead. gate-charter already ran locally before PR creation (line ~862).
_finale_check_ci(){
  local cid="$1" pr_num="$2"
  local _fin_dir="$STATE/finale-$cid"
  mkdir -p "$_fin_dir"

  # Load persistent state.
  local ci_state last_comment
  ci_state=$(cat "$_fin_dir/ci_state" 2>/dev/null || echo "")
  last_comment=$(cat "$_fin_dir/last_comment" 2>/dev/null || echo "")

  # Early-exit cache: ci_state=green → no external call needed (fix-2: written only on PASS).
  # fix-1: do NOT persist a cached "red" terminal state — that would create a permanent-stuck
  # regression identical to the GHA-CI bug this charter fixes.  verify-merged's internal cache
  # (CB_HOME/run/verify-cache) throttles repeat-call cost on retries.
  case "$ci_state" in
    green)   return 0 ;;
    timeout) return 2 ;;
  esac

  # AUTO merge (opt-in, #366/#401): perform the final charter→main merge automatically once
  # the verify-merged gate passes.  Opt-in via CB_AUTO_MERGE=1 (global) OR auto:merge label
  # on the charter issue (per-charter, #401).  Default off → PR waits for a human merge.
  local _charter_auto_merge
  _charter_auto_merge=$(gh issue view "$cid" -R "$CB_REPO" --json labels 2>/dev/null \
    | jq -r '[.labels[].name] | index("auto:merge") != null' 2>/dev/null || echo false)

  if [ "${CB_AUTO_MERGE:-0}" = "1" ] || [ "$_charter_auto_merge" = "true" ]; then
    # ── acceptance-convergence gate (#522): intercept auto-merge if acceptance_review_role set ──
    # Parse acceptance_review_role from manifest (same pattern as plan_review_role).
    # If role is set AND accept:agreed label is absent: route to status:acceptance-review,
    # clear term (CRITICAL: erases term=1 left by plan-approval paths), post idempotent
    # comment, and return 0 to block merge.  If role absent or accept:agreed present: fall through.
    # Step 6: this block must remain intact and BEFORE the verify-merged call.
    local _acc_review_role _acc_agreed
    _acc_review_role=$(manifest_policy "${CB_MANIFEST:-}" acceptance_review_role 2>/dev/null || true)
    if [ -n "$_acc_review_role" ]; then
      _acc_agreed=$(gh issue view "$cid" -R "$CB_REPO" --json labels 2>/dev/null \
        | jq -r '[.labels[].name] | index("accept:agreed") != null' 2>/dev/null || echo "false")
      if [ "$_acc_agreed" != "true" ]; then
        gh issue edit "$cid" -R "$CB_REPO" --add-label status:acceptance-review 2>/dev/null || true
        sset "$cid" term ""
        if [ "$last_comment" != "acceptance-pending" ]; then
          gh issue comment "$cid" -R "$CB_REPO" \
            --body "charter-finale: acceptance-convergence gate active — routing to acceptance review (acceptance_review_role=$_acc_review_role)" \
            2>/dev/null || true
          printf '%s' "acceptance-pending" > "$_fin_dir/last_comment"
        fi
        return 0
      fi
    fi

    # ── verify-merged gate (replaces GHA-CI gate, charter #685) ──────────────────
    # Mirror integrator lines 372-410: call verify-merged subcommand, extract RED_REASON,
    # and route by exit code.  Branch: charter/<cid>; base: main.
    local vm_exit=0 vm_out="" _vmreason=""
    vm_out=$(bash "$INTEGRATOR_SCRIPT" verify-merged "charter/$cid" "main" \
         --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>/dev/null) || vm_exit=$?
    _vmreason=$(printf '%s\n' "$vm_out" | sed -n 's/^RED_REASON: //p' | head -1)

    case "$vm_exit" in
      0)
        # verify-merged PASS: fix-2: write ci_state=green ONLY on PASS.
        printf '%s' "green" > "$_fin_dir/ci_state"
        log "charter-finale: #$cid PR #$pr_num verify-merged PASS → promoting + admin-merge"
        gh pr ready "$pr_num" -R "$CB_REPO" 2>/dev/null || true
        if gh pr merge "$pr_num" -R "$CB_REPO" --merge --admin 2>/dev/null; then
          log "charter-finale: #$cid PR #$pr_num AUTO-merged (admin) → main"
          gh issue close "$cid" -R "$CB_REPO" --reason completed 2>/dev/null || true
              # Prune merged charter from queue.json (non-blocking, atomic)
              { _qf="$RUN/queue.json"
                [ -f "$_qf" ] && \
                  _qt=$(mktemp -p "$RUN" q.XXXXXX.tmp 2>/dev/null) && \
                  jq --argjson c "$cid" \
                    'if .order then .order |= map(select(. != $c)) else . end' \
                    "$_qf" > "$_qt" 2>/dev/null && \
                  mv "$_qt" "$_qf" 2>/dev/null || \
                  rm -f "$_qt" 2>/dev/null; } || true
          printf '%s' "merged" > "$_fin_dir/last_comment"
          return 0
        fi
        log "charter-finale: #$cid PR #$pr_num admin-merge failed — left ready for human"
        ;;
      1)
        # Terminal RED: fix-1: do NOT persist a "red" cached state (avoids permanent-stuck regression).
        # fix-3: post idempotent comment on charter issue with RED_REASON (dedup via last_comment).
        log "charter-finale: #$cid verify-merged terminal RED: ${_vmreason:-RED}"
        if [ "$last_comment" != "verify-red" ]; then
          gh issue comment "$cid" -R "$CB_REPO" \
            --body "charter-finale: verify-merged RED (${_vmreason:-RED}) — deferring merge" \
            2>/dev/null || true
          printf '%s' "verify-red" > "$_fin_dir/last_comment"
        fi
        return 1
        ;;
      3)
        # Retryable: log and retry next tick.  No ci_state write.
        log "charter-finale: #$cid verify-merged retryable (exit 3) — retry next tick"
        return 1
        ;;
      *)
        # Infra error (exit 2) or other: log and retry.  No ci_state write.
        log "charter-finale: #$cid verify-merged infra error (exit $vm_exit) — retry next tick"
        return 1
        ;;
    esac
  fi

  # No auto-merge (or auto-merge admin-merge failed above): promote PR and post human-review
  # comment.  Write ci_state=green so the early-exit cache fires on subsequent ticks.
  log "charter-finale: #$cid PR #$pr_num CI green → promoting to ready"
  gh pr ready "$pr_num" -R "$CB_REPO" 2>/dev/null || true
  printf '%s' "green" > "$_fin_dir/ci_state"
  if [ "$last_comment" != "green" ]; then
    gh issue comment "$cid" -R "$CB_REPO" \
      --body "charter-finale: PR #$pr_num (charter/$cid → main) CI green — ready for human review" \
      2>/dev/null || true
    printf '%s' "green" > "$_fin_dir/last_comment"
  fi
  return 0

  # timeout case: handled by early-exit cache above (ci_state=timeout → return 2).
  # Kept here as documentation; unreachable unless ci_state is set externally to timeout.
  #   if [ "$last_comment" != "timeout" ]; then
  #     gh issue comment "$cid" -R "$CB_REPO" \
  #       --body "charter-finale: PR #$pr_num (charter/$cid → main) CI check timeout — stays draft" \
  #       2>/dev/null || true
  #     printf '%s' "timeout" > "$_fin_dir/last_comment"
  #   fi
  #   return 2
}

# ── charter auto-rebase helper (issue #255) ──────────────────────────────────
# _charter_autorebase <cid> <branch>
# Attempts to merge origin/main into charter/<cid> in a fresh clone.
# Returns:
#   0 — merge succeeded (clean or sha-only manifest conflict auto-resolved),
#       charter/<cid> pushed to remote; caller may proceed with finale.
#   2 — real conflicts exist; caller should escalate (label + continue).
#   other — infra error; caller should retry next tick.
#
# sha-only conflict resolution: when the ONLY conflicting file is
# reference/runtime-manifest.tsv, resolve via `git checkout --theirs` (main
# is the superset) + regen-manifest.sh (refreshes sha column from actual files)
# then commit and push.  This mirrors the manual fix applied for #131.
_charter_autorebase(){
  local cid="$1" branch="$2"
  local tmp; tmp=$(mktemp -d) || return 1
  # Clone and checkout the charter branch
  git clone -q "$GIT_REMOTE" "$tmp/r" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  git -C "$tmp/r" config user.email "crewboss-launcher@autorebase" 2>/dev/null || true
  git -C "$tmp/r" config user.name  "crewboss-launcher"            2>/dev/null || true
  git -C "$tmp/r" checkout -q "$branch" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  # Attempt merge of origin/main (already fetched by clone)
  local merge_rc=0
  git -C "$tmp/r" merge origin/main --no-edit 2>/dev/null || merge_rc=$?
  if [ "$merge_rc" = "0" ]; then
    # Clean merge — push and done
    git -C "$tmp/r" push origin "$branch" 2>/dev/null \
      || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
  fi
  # Merge produced conflicts — inspect them
  local cf
  cf=$(git -C "$tmp/r" diff --name-only --diff-filter=U 2>/dev/null) || cf=""
  # Check if ALL conflicting files are in the manifest-only set
  local non_manifest; non_manifest=$(printf '%s\n' "$cf" \
    | grep -v '^reference/runtime-manifest\.tsv$' | grep -v '^$') || non_manifest=""
  if [ -n "$non_manifest" ]; then
    # Real conflicts outside the manifest — abort and escalate
    git -C "$tmp/r" merge --abort 2>/dev/null || true
    rm -rf "$tmp"
    return 2
  fi
  # Only manifest conflicts: resolve via --theirs (main superset) + regen
  git -C "$tmp/r" checkout --theirs reference/runtime-manifest.tsv 2>/dev/null \
    || { git -C "$tmp/r" merge --abort 2>/dev/null || true; rm -rf "$tmp"; return 1; }
  git -C "$tmp/r" add reference/runtime-manifest.tsv 2>/dev/null || true
  bash "$tmp/r/reference/bin/regen-manifest.sh" "$tmp/r" 2>/dev/null || true
  git -C "$tmp/r" add -A 2>/dev/null || true
  git -C "$tmp/r" commit --no-edit 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  git -C "$tmp/r" push origin "$branch" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

# ── test-quality gate cycle (charter #597) ───────────────────────────────────
# Called every tick of cmd_run after _integrator_cycle, before _charter_finale_cycle.
# SCOPED execution only — no-op in unscoped/multi-charter mode (bootstrap caveat #193).
#
# Fires after BOTH the qa-engineer AND impl leaves have merged (all leaves closed).
# One gate run per charter (tracked via launcher-local tqg state on the charter id).
#
# Routing signals:
#   status:test-broken  — qa-engineer leaf re-dispatched (test is broken)
#   status:impl-broken  — executor leaf re-dispatched (impl is broken)
#
# Sub-step A: re-dispatch routing — detect open type:agent leaves that already carry
#   status:test-broken or status:impl-broken and ensure status:needs-rework is set so
#   the launcher's existing rework path picks them up for re-dispatch.
# Sub-step B: gate invocation — when all leaves for the scoped charter are closed and
#   the gate has not yet run (tqg state absent), find the qa-engineer and executor
#   leaves and invoke run-test-quality-gate.sh.
_tqg_cycle(){
  # Scoped execution only (CREWBOSS_CHARTER must be set — bootstrap caveat #193)
  [ "$CHARTER_SCOPE" = "0" ] && return 0
  local cid="$CHARTER_SCOPE"
  local tqg_script="$HERE_LAUNCHER/run-test-quality-gate.sh"

  # ── Sub-step A: ensure needs-rework on open leaves carrying routing labels ──
  # The gate script applies status:test-broken or status:impl-broken and reopens
  # the issue. This sub-step adds status:needs-rework (idempotent) so the launcher's
  # existing rework dispatch path claims it on the next tick.
  local _tqg_routing_leaves _tqg_rl
  _tqg_routing_leaves=$(_cb_issue_list open 2>/dev/null | jq -r --argjson c "$cid" '
      def numsAfter($b; $k):
        [($b // "") | split("\n")[]
          | select(test("(?i)^[\\s*_>#-]*" + $k + "\\s*:"))]
        | join(" ") | [scan("\\d+") | tonumber];
      .[] | select([.labels[].name] | index("type:agent") != null)
          | select((numsAfter(.body; "Charter") | first) == ($c | tonumber))
          | select([.labels[].name] |
              (index("status:test-broken") != null or index("status:impl-broken") != null))
          | select([.labels[].name] | index("status:needs-rework") == null)
          | .number' 2>/dev/null || true)
  for _tqg_rl in $_tqg_routing_leaves; do
    gh issue edit "$_tqg_rl" -R "$CB_REPO" \
      --add-label "status:needs-rework" >/dev/null 2>&1 || true
    log "tqg: #$_tqg_rl routing label (test-broken/impl-broken) → adding status:needs-rework"
  done

  # ── Sub-step B: gate invocation ──────────────────────────────────────────────
  # Guard: gate script must be available
  [ -f "$tqg_script" ] || { log "tqg: gate script not found ($tqg_script) — skipping"; return 0; }

  # Guard: already ran for this charter in this launcher session
  local _tqg_state
  _tqg_state=$(sget "$cid" tqg)
  [ "$_tqg_state" = "done" ] && return 0

  # Guard: all leaves for this charter must be closed (same condition as finale)
  local _tqg_open
  _tqg_open=$(_cb_issue_list open 2>/dev/null | jq -r --argjson c "$cid" '
      def numsAfter($b; $k):
        [($b // "") | split("\n")[]
          | select(test("(?i)^[\\s*_>#-]*" + $k + "\\s*:"))]
        | join(" ") | [scan("\\d+") | tonumber];
      [ .[] | select([.labels[].name] | index("type:charter") == null)
            | select((numsAfter(.body; "Charter") | first) == ($c | tonumber)) ]
      | length' 2>/dev/null || echo "1")
  [ "${_tqg_open:-1}" = "0" ] || return 0   # leaves still open — not ready

  # Find the qa-engineer leaf (closed type:agent with role:qa-engineer label)
  local _qa_leaf
  _qa_leaf=$(_cb_issue_list closed 2>/dev/null | jq -r --argjson c "$cid" '
      def numsAfter($b; $k):
        [($b // "") | split("\n")[]
          | select(test("(?i)^[\\s*_>#-]*" + $k + "\\s*:"))]
        | join(" ") | [scan("\\d+") | tonumber];
      [ .[] | select([.labels[].name] | index("type:agent") != null)
            | select([.labels[].name] | index("role:qa-engineer") != null)
            | select((numsAfter(.body; "Charter") | first) == ($c | tonumber)) ]
      | first | .number // empty' 2>/dev/null || true)

  # Find the executor/impl leaf (closed type:agent with role:executor label)
  local _impl_leaf
  _impl_leaf=$(_cb_issue_list closed 2>/dev/null | jq -r --argjson c "$cid" '
      def numsAfter($b; $k):
        [($b // "") | split("\n")[]
          | select(test("(?i)^[\\s*_>#-]*" + $k + "\\s*:"))]
        | join(" ") | [scan("\\d+") | tonumber];
      [ .[] | select([.labels[].name] | index("type:agent") != null)
            | select([.labels[].name] | index("role:executor") != null)
            | select((numsAfter(.body; "Charter") | first) == ($c | tonumber)) ]
      | first | .number // empty' 2>/dev/null || true)

  # Skip TQG if this charter does not have both qa-engineer and executor leaves
  # (not all charters follow the qa-engineer+executor TDD pattern)
  if [ -z "$_qa_leaf" ] || [ -z "$_impl_leaf" ]; then
    log "tqg: charter #$cid — qa-leaf or impl-leaf not found; skipping TQG"
    sset "$cid" tqg "done"   # mark done so this check is not repeated every tick
    return 0
  fi

  log "tqg: running gate for charter #$cid (qa-leaf=#$_qa_leaf impl-leaf=#$_impl_leaf)"
  local _tqg_rc=0
  bash "$tqg_script" \
    --charter  "$cid" \
    --qa-leaf  "$_qa_leaf" \
    --impl-leaf "$_impl_leaf" \
    --repo     "$CB_REPO" \
    || _tqg_rc=$?

  if [ "$_tqg_rc" = "0" ]; then
    sset "$cid" tqg "done"
    log "tqg: gate green for charter #$cid → tqg:done (finale may proceed)"
  elif [ "$_tqg_rc" = "1" ]; then
    log "tqg: gate routed for charter #$cid — leaf re-dispatched for rework"
    # tqg state left unset: gate will re-run after the rework leaf re-closes
  else
    log "tqg: gate infra error for charter #$cid (rc=$_tqg_rc) — will retry"
  fi
}

# ── charter finale cycle ──────────────────────────────────────────────────────
# Called every tick of cmd_run after _integrator_cycle.
# For each OPEN charter C where ALL leaves (Charter: #C issues) are CLOSED and
# charter/C exists ahead of main:
#   1. Run LOCAL gate BEFORE creating PR (marker-grep mandatory; CB_HARNESS optional).
#      MUST NOT read CI checks at this stage (PR doesn't exist yet — anti-deadlock).
#   2. Gate green → open draft PR charter/C → main.
#   3. Local gate proven green → CI decoupled; mark ci_state=green immediately.
#   4. Green → promote (gh pr ready) + comment; gate re-run on restart (red stays draft + comment).
# Idempotent: existing open PR is re-checked, not duplicated.
# Charter stays OPEN — only a human (tech-lead) merges and closes it.
_charter_finale_cycle(){
  [ -n "$GIT_REMOTE" ] || return 0   # silence: already logged by _integrator_cycle
  [ -x "$INTEGRATOR_SCRIPT" ] || { log "charter-finale: integrator not found: $INTEGRATOR_SCRIPT"; return 0; }

  # Snapshot the board (single gh call)
  local all_issues
  all_issues=$(_cb_issue_list all 2>/dev/null) || all_issues="[]"

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
    if [ "$_anc_rc" != "0" ]; then
      # main is NOT an ancestor of charter/C — attempt auto-rebase (#255)
      local _ar_rc=0
      _charter_autorebase "$cid" "$branch" || _ar_rc=$?
      if [ "$_ar_rc" = "0" ]; then
        log "charter-finale: #$cid auto-rebased onto main"
        # Re-verify ancestor after successful rebase
        local _arc2_tmp _arc2_rc
        _arc2_tmp=$(mktemp -d)
        git clone -q --bare "$GIT_REMOTE" "$_arc2_tmp/repo" 2>/dev/null \
          || { rm -rf "$_arc2_tmp"; continue; }
        _arc2_rc=0
        git -C "$_arc2_tmp/repo" merge-base --is-ancestor \
          "main" "$branch" 2>/dev/null || _arc2_rc=$?
        rm -rf "$_arc2_tmp"
        [ "$_arc2_rc" = "0" ] || { log "charter-finale: #$cid still not ancestor after rebase — skip"; continue; }
        # Fall through to normal finale processing
      elif [ "$_ar_rc" = "2" ]; then
        log "charter-finale: #$cid real conflicts with main — needs conflict-resolution"
        gh issue edit "$cid" -R "$CB_REPO" \
          --add-label status:needs-conflict-resolution 2>/dev/null || true
        continue
      else
        log "charter-finale: #$cid autorebase infra error (rc=$_ar_rc) — will retry next tick"
        continue
      fi
    fi

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

    # ── #206 Part A: persist the regenerated manifest sha-lock as a COMMIT on ──
    # charter/C BEFORE the PR is created. The full suite just passed on this tree
    # (gate green), so refreshing the sha-lock is sound (manifest==verified tree).
    # The subsequent human charter→main merge carries the fresh manifest onto
    # canon, keeping doctor's deploy-vs-manifest integrity true at the canon
    # boundary. Infra (clone/push) → defer the PR to the next tick so main never
    # receives a stale manifest. No-op (no commit) when already fresh.
    local regen_out regen_rc=0
    regen_out=$(bash "$INTEGRATOR_SCRIPT" regen-persist "$cid" \
                  --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>&1) || regen_rc=$?
    if [ "$regen_rc" -ne 0 ]; then
      log "charter-finale: #$cid regen-persist infra (rc=$regen_rc) — PR deferred to next tick: $regen_out"
      continue
    fi
    [ -n "$regen_out" ] && log "charter-finale: #$cid regen-persist: $regen_out"

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

# _serializing_charter: in unscoped mode, return the min-numbered OPEN charter with
# label blast-radius:high (type:charter + OPEN + blast-radius:high). Empty if none.
# Called once per cmd_run tick; cheap (single gh issue list, same pattern as _loop_is_alive). [#262]
_serializing_charter(){
  local _s
  _s=$(_cb_issue_list open 2>/dev/null || echo "[]")
  printf '%s' "$_s" | jq -r '
    [ .[] | select(.state=="OPEN")
          | select([.labels[].name] | index("type:charter") != null)
          | select([.labels[].name] | index("blast-radius:high") != null)
    ] | sort_by(.number) | first | .number // empty' 2>/dev/null || true
}

# re-dispatch <leaf-id> — operator command AND the I-D idempotent re-dispatch primitive:
# atomically clear launcher-local run-state, remove the poisoned work tree, and re-queue the
# leaf as launchable (status:needs-rework). Deliberate operator action — never auto-fired.
cmd_redispatch(){
  local id="${1:-}"
  [ -n "$id" ] || { echo "usage: $0 re-dispatch <leaf-id>" >&2; return 64; }
  local sd="$STATE/$id" wd="$RUN/work/$id" k
  for k in pid term tries pr_head stale_ticks rework_n infra_attempt infra_next_retry_ts; do rm -f "$sd/$k" 2>/dev/null || true; done
  rm -rf "$wd" 2>/dev/null || sudo rm -rf "$wd" 2>/dev/null || true
  gh issue edit "$id" -R "$CB_REPO" \
    --remove-label status:review --remove-label status:blocked --remove-label status:in-progress \
    --add-label status:needs-rework >/dev/null 2>&1 || true
  log "re-dispatch #$id: run-state cleared, work tree removed, routed status:needs-rework (re-launchable)"
}

cmd_once(){
  ( exec {lockfd}>"$LOCK"
    # Root B (#1096): hold the flock on an auto-assigned high fd ({lockfd}, >=10) instead of
    # the old hard-coded fd 9. The OUTER subshell keeps {lockfd} open to hold the lock; the
    # whole cycle body runs in an INNER subshell with {lockfd} CLOSED (`{lockfd}>&-`), so NO
    # backgrounded spawn — claim_and_spawn or ANY other site — inherits the lock fd. That
    # severs lock-fd inheritance at every spawn site at once (a per-site `9>&-` point-fix
    # would miss the non-claim_and_spawn sites), so a hung/slow spawn can never keep
    # launcher.lock held after the loop subshell is gone and wedge keepalive recovery.
    flock -n "$lockfd" || { log "another launcher holds the lock — exit"; exit 1; }
    ( reconcile
    # ── queue-mode detection ─────────────────────────────────────────────────
    # Read $RUN/queue.json (.order[]); if non-empty, only the head-of-queue
    # charter (first in order not yet terminal-for-queue) may have leaves launched.
    # Terminal-for-queue: done, blocked, or plan-review that is genuinely a human-park
    # (no plan_review_role configured, OR plan:agreed already present).  A plan-review
    # charter with plan_review_role AND without plan:agreed is non-terminal — it is
    # eligible to become head so the plan-convergence gate picks it up next tick (#382).
    # Absent/unreadable/empty order → no change in behaviour.
    local _q_order="" _q_head="" _q_disp="" _qn="" _qst="" _id_ch="" _prr_q="" _plag_q=""
    _q_order=$(jq -r '.order[]' "$RUN/queue.json" 2>/dev/null) || _q_order=""
    if [ -n "$_q_order" ]; then
      for _qn in $_q_order; do
        _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
        case "$_qst" in
          done|blocked|hold|deferred) continue ;;
          plan-review)
            # Skip plan-review only when terminal: no plan_review_role (human-park path)
            # or plan:agreed already set (convergence complete).
            _prr_q=$(manifest_policy "${CB_MANIFEST:-}" plan_review_role 2>/dev/null || true)
            if [ -z "$_prr_q" ]; then continue; fi
            _plag_q=$(gh issue view "$_qn" -R "$CB_REPO" --json labels 2>/dev/null \
                      | jq -r '[.labels[].name] | index("plan:agreed") != null' 2>/dev/null || echo "false")
            [ "$_plag_q" = "true" ] && continue
            ;;
        esac
        _q_head="$_qn"; break
      done
      _q_disp=$(printf '%s' "$_q_order" | tr '\n' ',' | sed 's/,$//')
      log "queue-mode: order=[$_q_disp] head=#${_q_head:-none}"
    fi
    local ids id launched=0 rc
    ids=$(board launchable)
    for id in $ids; do
      # queue-mode filter: only the head charter's leaves are eligible
      if [ -n "$_q_order" ]; then
        if [ -z "$_q_head" ]; then log "queue-mode: queue exhausted — no eligible head"; break; fi
        _id_ch=$(board get "$id" charter 2>/dev/null || echo "")
        [ "$_id_ch" = "$_q_head" ] || continue
      fi
      [ "$launched" -ge "$MAXP" ] && { log "parallel cap reached"; break; }
      claim_and_spawn "$id"; rc=$?
      launched=$((launched+1))
      [ "$rc" = "9" ] && break
    done
    log "cycle done: launched=$launched"
    ) {lockfd}>&-
  )
}

# --- run: background-parallel poll-loop (§4.6) ---
# Backgrounds each spawn (up to CB_MAX_PARALLEL concurrent), routes by status.json when the
# spawn process finishes (not by a blocking exit code), reconciles orphans, exits when idle.
running_count(){ local d id pid n=0
  for d in "$STATE"/*/; do [ -e "$d" ] || continue; id=$(basename "$d"); pid=$(sget "$id" pid)
    [ -n "$pid" ] && [ "$pid" != PENDING ] && kill -0 "$pid" 2>/dev/null && n=$((n+1)); done
  echo "$n"; }
cmd_run(){
  ( exec {lockfd}>"$LOCK"
    # Root B (#1096): hold the flock on an auto-assigned high fd ({lockfd}, >=10) instead of
    # the old hard-coded fd 9. The OUTER subshell keeps {lockfd} open to hold the lock; the
    # whole loop body runs in an INNER subshell with {lockfd} CLOSED (`{lockfd}>&-`), so NO
    # backgrounded spawn (claim_and_spawn, TRIAGE, ANALYSIS, REVIEW, APPROVAL, CONFLICT,
    # PLAN, PLAN_REVIEW, ACCEPT_REVIEW, integrator bg_spawn, …) inherits the lock fd. That
    # severs lock-fd inheritance at every spawn site at once (a per-site `9>&-` point-fix
    # would miss the non-claim_and_spawn sites): a hung/slow spawn — even a detached
    # grandchild — can no longer keep launcher.lock held after the loop subshell exits and
    # wedge keepalive recovery.
    flock -n "$lockfd" || { log "another launcher holds the lock — exit"; exit 1; }
    # Root C (#1096): write run/launcher.pid UNDER the flock so it appears only once the
    # loop genuinely owns the lock (a foreign holder makes us lose the flock above and
    # exit without clobbering its view). This is the single liveness source the API and
    # keepalive read via os.kill(pid,0). Overwriting a stale pid here reaps an orphaned
    # lock: if the lock was free, the previous loop is dead and its pid-file is replaced.
    # The EXIT trap removes it when this loop exits so a dead loop leaves no zombie pid.
    echo "$$" > "$RUN/launcher.pid"
    trap 'rm -f "$RUN/launcher.pid"' EXIT
    ( local poll="${CB_POLL:-2}" maxticks="${CB_MAX_TICKS:-120}" ticks=0 stop="" id pid ph prev tries running idle_ticks=0 _q_order="" _q_head="" _q_plan_head="" _q_accept_head="" _q_disp="" _qn="" _qst="" _id_ch=""
    reconcile   # STARTUP ONLY: requeue orphans from a previous run/reboot. Inside the loop,
                # the launcher started its own spawns, so a dead pid = finished (route by
                # status.json) — NOT an orphan; running reconcile per-tick would requeue every
                # normally-finished spawn before route-finished could route it.
    while :; do
      # kill-switch: stop the loop now (running spawns finish on their own / next reconcile).
      # exit 42: kill-switch-blocked (machine-readable; hint: unkill to clear the flag).
      [ -f "$RUN/kill_switch" ] && { log "kill-switch present — run blocked (hint: unkill to clear $RUN/kill_switch)"; exit 42; }
      # ── rate-limit backoff (charter #1004): defer gh-heavy work when remaining < floor,
      #    so the loop never drives the primary REST limit to 0 (the #996 paralysis). ──
      _cb_rl_backoff || true
      # ── one-fetch-per-tick (charter #1004): prime/refresh the in-memory issue snapshot
      #    ONCE here (conditional If-None-Match, sort=updated). Every _cb_issue_list call
      #    site below then serves from this snapshot at no extra primary-RL cost. ──
      _cb_tick_cache_refresh
      # route finished background spawns (by status.json phase; phase=unknown -> treat as crash/fail)
      for d in "$STATE"/*/; do [ -e "$d" ] || continue; id=$(basename "$d"); pid=$(sget "$id" pid)
        { [ -n "$pid" ] && [ "$pid" != PENDING ]; } || continue
        if kill -0 "$pid" 2>/dev/null; then
          # [#212 I4 hang-protection] kill a spawn alive past CB_SPAWN_TIMEOUT (wall-clock), route like crash
          _st=$(sget "$id" starttime)
          if [ -n "$_st" ]; then
            _ste=$(date -u -d "$_st" +%s 2>/dev/null || echo 0)
            _age=$(( $(date -u +%s) - _ste ))
            _kind=$(sget "$id" kind)
            _kind_upper=$(printf '%s' "$_kind" | tr '[:lower:]-' '[:upper:]_')
            eval "_eff_timeout=\${CB_${_kind_upper}_SPAWN_TIMEOUT:-${CB_SPAWN_TIMEOUT:-1800}}"
            if [ "$_ste" -gt 0 ] && [ "$_age" -gt "$_eff_timeout" ]; then
              kill -9 "$pid" 2>/dev/null
              prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
              if [ "$tries" -ge "$RETRY_CAP" ]; then board route "$id" blocked "spawn timeout >${_eff_timeout}s ($tries×, retry-cap)" >/dev/null; sset "$id" term 1; log "#$id spawn timeout (>${_eff_timeout}s) -> kill -9 + blocked"
              else board route "$id" requeue >/dev/null; log "#$id spawn timeout (>${_eff_timeout}s) -> kill -9 + requeue"; fi
              sset "$id" pid ""
            fi
          fi
          continue          # still running (or just timed-out+routed)
        fi
        # [#619 exec-592] completion-detect guard: pid gone but phase=starting (spawn killed before
        # writing final status.json) — check run.log for a PR URL (nsjail-detach race).
        if _phase=$(jq -r '.phase // ""' "$RUN/work/$id/status.json" 2>/dev/null) && [ "$_phase" = "starting" ]; then
          _pr_url=$(grep -oE 'https://github.com/[^ "]+/pull/[0-9]+' "$RUN/work/$id/run.log" 2>/dev/null | tail -1)
          if [ -z "$_pr_url" ]; then
            _leaf_branch="$(board get "$id" branch 2>/dev/null || true)"
            [ -n "$_leaf_branch" ] && _pr_url=$(gh pr list --head "$_leaf_branch" --state open --json url -q '.[0].url' 2>/dev/null || true)
          fi
          if [ -n "$_pr_url" ]; then
            log "#$id pid gone but PR found ($_pr_url), routing done (nsjail-detach race)"
            sset "$id" pr "$_pr_url"
            sset "$id" tries 0
            board route "$id" review >/dev/null
            sset "$id" term 1; sset "$id" pid ""
            continue
          fi
        fi
        # analysis task: route by charter state; success = team-review, fail = retry/blocked.
        if [ "$(sget "$id" kind)" = "analysis" ]; then
          cst=$(board get "$id" state)
          if [ "$cst" = "team-review" ]; then
            # Success: clear pid, term, AND tries (F-1 contract — do NOT set term=1)
            sset "$id" pid ""; sset "$id" term ""; sset "$id" tries ""
            log "#$id analysis done -> team-review"
          else
            # Failure (still needs-analysis or needs-plan): increment tries
            prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then
              board route "$id" blocked "analysis failed $tries× (retry-cap $RETRY_CAP)" >/dev/null
              sset "$id" pid ""; sset "$id" term 1
              log "#$id analysis failed ($tries) -> blocked"
            else
              # Clear pid only; re-entrant condition in analysis-cycle picks it up next tick
              sset "$id" pid ""
              log "#$id analysis failed ($tries) -> retry"
            fi
          fi
          continue
        fi
        # review task (#334 convergence): success = review:agreed set OR charter sent to needs-analysis.
        if [ "$(sget "$id" kind)" = "review" ]; then
          cst=$(board get "$id" state)
          _agr=$(gh issue view "$id" -R "$CB_REPO" --json labels 2>/dev/null | jq -r '[.labels[].name] | index("review:agreed") != null' 2>/dev/null || echo "false")
          if [ "$_agr" = "true" ] || [ "$cst" = "needs-analysis" ]; then
            sset "$id" pid ""; sset "$id" term ""; sset "$id" tries ""
            log "#$id review done -> $([ "$_agr" = "true" ] && echo agreed || echo changes-requested)"
          else
            prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then
              board route "$id" blocked "review failed $tries× (retry-cap $RETRY_CAP)" >/dev/null
              sset "$id" pid ""; sset "$id" term 1
              log "#$id review failed ($tries) -> blocked"
            else
              sset "$id" pid ""
              log "#$id review failed ($tries) -> retry"
            fi
          fi
          continue
        fi
        # plan-review task (#382 plan-convergence): analyst reviews tech-lead's PLAN.
        # success = plan:agreed set OR charter sent to needs-plan (critique → tech-lead re-plans).
        if [ "$(sget "$id" kind)" = "plan-review" ]; then
          cst=$(board get "$id" state)
          _plok=$(gh issue view "$id" -R "$CB_REPO" --json labels 2>/dev/null | jq -r '[.labels[].name] | index("plan:agreed") != null' 2>/dev/null || echo "false")
          if [ "$_plok" = "true" ] || [ "$cst" = "needs-plan" ]; then
            sset "$id" pid ""; sset "$id" term ""; sset "$id" tries ""
            log "#$id plan-review done -> $([ "$_plok" = "true" ] && echo agreed || echo changes-requested)"
            # ── GC stale type:agent leaves (#444) ────────────────────────────────────
            # When the plan-reviewer routes the charter back to needs-plan (critique
            # path), the current plan is superseded by the tech-lead's re-plan.  Close
            # all open type:agent leaves of THIS charter so stale work-items do not
            # execute against the outdated decomposition.
            # numsAfter numeric equality: "Charter: #5" does NOT match "Charter: #50".
            if [ "$cst" = "needs-plan" ]; then
              _gc_snap=$(_cb_issue_list open 2>/dev/null || echo "[]")
              for _gc_lid in $(printf '%s' "$_gc_snap" | jq -r --argjson c "$id" '
                def numsAfter($b; $k):
                  [ ($b // "") | split("\n")[]
                    | select(test("(?i)^[\\s*_>#-]*" + $k + "\\s*:")) ]
                  | join(" ") | [scan("\\d+") | tonumber];
                .[] | select(.state == "OPEN")
                    | select([.labels[].name] | index("type:agent") != null)
                    | select((numsAfter(.body; "Charter") | first) == ($c | tonumber))
                    | .number' 2>/dev/null); do
                gh issue close "$_gc_lid" -R "$CB_REPO" 2>/dev/null || true
                log "gc-stale-leaves: closed type:agent leaf #$_gc_lid (charter #$id critique → needs-plan)"
              done
            fi
          else
            prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then
              board route "$id" blocked "plan-review failed $tries× (retry-cap $RETRY_CAP)" >/dev/null
              sset "$id" pid ""; sset "$id" term 1
              log "#$id plan-review failed ($tries) -> blocked"
            else
              sset "$id" pid ""
              log "#$id plan-review failed ($tries) -> retry"
            fi
          fi
          continue
        fi
        # acceptance-review task (#522 acceptance-convergence): route by accept:agreed label.
        # Purpose: prevent fall-through to status.json reader for charter ids with no status.json.
        # Clears pid unconditionally; if accept:agreed is set, also clears term and aound.
        # UNCONDITIONAL continue — last statement before closing fi.
        if [ "$(sget "$id" kind)" = "acceptance-review" ]; then
          sset "$id" pid ""
          _acrd_agreed=$(gh issue view "$id" -R "$CB_REPO" --json labels 2>/dev/null \
            | jq -r '[.labels[].name] | index("accept:agreed") != null' 2>/dev/null || echo "false")
          if [ "$_acrd_agreed" = "true" ]; then
            sset "$id" term ""
            sset "$id" aound 0
          fi
          continue
        fi
        # approval task: route by charter state; success = left team-review, fail = retry/blocked.
        # F-1 contract: successful approve (→needs-plan) or reject (→needs-analysis) both count as
        # success; CLEAR pid, term AND tries so the next stage can claim the charter without guards.
        if [ "$(sget "$id" kind)" = "approval" ]; then
          cst=$(board get "$id" state)
          if [ "$cst" != "team-review" ]; then
            # Success: charter left team-review (→needs-plan approved, or →needs-analysis rejected)
            sset "$id" pid ""; sset "$id" term ""; sset "$id" tries ""
            log "#$id approval done -> $cst"
          else
            # Failure: still in team-review → increment tries; at cap → blocked + term=1
            prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then
              board route "$id" blocked "approval failed $tries× (retry-cap $RETRY_CAP)" >/dev/null
              sset "$id" pid ""; sset "$id" term 1
              log "#$id approval failed ($tries) -> blocked"
            else
              sset "$id" pid ""
              log "#$id approval failed ($tries) -> retry"
            fi
          fi
          continue
        fi
        # charter planning task (tech-lead): route by the charter's own label, not by review.
        if [ "$(sget "$id" kind)" = "charter" ]; then
          cst=$(board get "$id" state)
          if [ "$cst" = "plan-review" ] || [ "$cst" = "approved" ]; then
            # PLAN-convergence (#382): when plan_review_role is configured, the tech-lead's plan is
            # NOT terminal at plan-review — the analyst reviews it (plan-review gate fires while term
            # is unset). Released to status:approved only on plan:agreed. Default off → existing flow.
            _plrr=$(manifest_policy "${CB_MANIFEST:-}" plan_review_role 2>/dev/null || true)
            _raw_labels_json=$(gh issue view "$id" -R "$CB_REPO" --json labels 2>/dev/null | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
            _plag=$(printf '%s' "$_raw_labels_json" | jq -r 'index("plan:agreed")!=null' 2>/dev/null || echo false)
            # Per-charter auto:plan-approve label (OR with global CB_AUTO_PLAN_APPROVE env var, #401).
            _auto_plan_approve_label=$(printf '%s' "$_raw_labels_json" | jq -r 'index("auto:plan-approve")!=null' 2>/dev/null || echo false)
            if [ -n "$_plrr" ] && [ "$cst" = "plan-review" ] && [ "$_plag" != "true" ]; then
              log "#$id planned -> plan-review (awaiting plan-convergence)"   # term stays unset → gate picks up
            else
              # Leaf-count gate: require_decomp_leaves policy (default OFF — zero regression).
              # MUST run before auto-approve: prevents premature status:approved when 0 leaves.
              _rdl=$(manifest_policy "${CB_MANIFEST:-}" require_decomp_leaves 2>/dev/null || true)
              if [ -n "$_rdl" ] && [ "$cst" = "plan-review" ]; then
                _leaf_count=$(_cb_issue_list all 2>/dev/null \
                  | jq -r --argjson c "$id" \
                    '[.[] | select([.labels[].name] | any(. == "type:agent"))
                           | select((.body // "") | test("(?i)Charter:\\s*#?" + ($c|tostring)))] | length' \
                  2>/dev/null) || _leaf_count=0
                if [ "${_leaf_count:-0}" -eq 0 ]; then
                  prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
                  if [ "$tries" -ge "$RETRY_CAP" ]; then
                    gh issue edit "$id" -R "$CB_REPO" --remove-label status:plan-review 2>/dev/null || true
                    board route "$id" blocked "decomposition incomplete: 0 leaves created" >/dev/null
                    sset "$id" pid ""; sset "$id" term 1
                    log "#$id leaf-count gate: 0 leaves, tries=$tries >= RETRY_CAP -> blocked"
                  else
                    gh issue edit "$id" -R "$CB_REPO" \
                      --remove-label status:plan-review --add-label status:needs-plan 2>/dev/null || true
                    sset "$id" pid ""
                    log "#$id leaf-count gate: 0 leaves, tries=$tries -> re-route to needs-plan"
                  fi
                  continue
                fi
              fi
              # AUTO plan-approval (opt-in, #366/#401): release leaves automatically (no plan-convergence).
              # Opt-in via CB_AUTO_PLAN_APPROVE=1 (global) OR auto:plan-approve label on the charter
              # issue (per-charter, #401). Default off → charter waits for human plan approval.
              if ([ "${CB_AUTO_PLAN_APPROVE:-0}" = "1" ] || [ "$_auto_plan_approve_label" = "true" ]) && [ "$cst" = "plan-review" ] && [ -z "$_plrr" ]; then
                gh issue edit "$id" -R "$CB_REPO" --remove-label status:plan-review --add-label status:approved 2>/dev/null || true
                log "#$id plan auto-approved (CB_AUTO_PLAN_APPROVE or auto:plan-approve label) -> approved"
              fi
              sset "$id" term 1; log "#$id planned -> $cst"
            fi
          else prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then sset "$id" term 1; board route "$id" blocked "tech-lead failed to decompose ($tries×)" >/dev/null; log "#$id plan failed -> blocked"
            else log "#$id plan failed -> retry"; fi
          fi
          sset "$id" pid ""; continue
        fi
        # conflict-resolution task (git-resolver): success = label status:needs-conflict-resolution
        # was removed by git-resolver; failure = label still present → retry/blocked. [#187 L2]
        if [ "$(sget "$id" kind)" = "conflict-resolution" ]; then
          _cr_labels=$(gh issue view "$id" -R "$CB_REPO" --json labels \
                       2>/dev/null | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
          _still_conflict=$(printf '%s' "$_cr_labels" \
                            | jq -r 'index("status:needs-conflict-resolution") != null' \
                            2>/dev/null || echo "true")
          if [ "$_still_conflict" = "false" ]; then
            # Success: conflict resolved — clear pid, term, AND tries (F-1 contract)
            sset "$id" pid ""; sset "$id" term ""; sset "$id" tries ""
            log "#$id conflict-resolution done"
          else
            # Failure: still needs-conflict-resolution → increment tries
            prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
            if [ "$tries" -ge "$RETRY_CAP" ]; then
              board route "$id" blocked "conflict-resolution failed $tries× (retry-cap $RETRY_CAP)" >/dev/null
              sset "$id" pid ""; sset "$id" term 1
              log "#$id conflict-resolution failed ($tries) -> blocked"
            else
              sset "$id" pid ""
              log "#$id conflict-resolution failed ($tries) -> retry"
            fi
          fi
          continue
        fi
        # kind=recovery completion handler (charter #1049): sibling of kind=triage. Drives the
        # NEW cross-TICK recovery state machine. Fires whenever a kind=recovery spawn finishes:
        #   - recovery_plan EMPTY  -> the recovery-lead manager just posted: ingest the plan (b).
        #   - recovery_plan SET    -> a re-dispatched step executor finished: read the re-verify
        #                             outcome and advance the cursor / honor terminal (c)/(d).
        if [ "$(sget "$id" kind)" = "recovery" ]; then
          _rplan=$(sget "$id" recovery_plan)
          if [ -z "$_rplan" ]; then
            # (b) plan ingestion + cursor persistence: read the latest ## Recovery (machine)
            # comment, parse it with recovery-parse.sh, persist plan + cursor.
            _rcmt=$(gh issue view "$id" -R "$CB_REPO" --json comments 2>/dev/null \
              | jq -r '[.comments[]?.body | select(contains("## Recovery (machine)"))] | last // empty' \
              2>/dev/null || true)
            if [ -z "$_rcmt" ]; then
              log "#$id kind=recovery: no ## Recovery (machine) comment found — deferring"
              _recovery_terminal "$id" "no-recovery-plan" "recovery-lead posted no machine plan"
              continue
            fi
            _rtsv=$(printf '%s\n' "$_rcmt" | bash "$CB_RECOVERY_PARSE" 2>/dev/null) || {
              log "#$id kind=recovery: recovery-parse rejected the plan — deferring"
              _recovery_terminal "$id" "recovery-plan-parse-failed" "recovery-parse.sh rejected the plan block"
              continue
            }
            sset "$id" recovery_plan "$_rtsv"
            sset "$id" recovery_cursor 0
            sset "$id" pid ""
            log "#$id recovery: plan ingested ($(printf '%s\n' "$_rtsv" | awk -F'\t' '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ') steps) — dispatching cursor 0"
            _recovery_dispatch_step "$id"
            continue
          fi
          # (c) step executor outcome (cross-TICK): the re-dispatched step's executor finished.
          _rcursor=$(sget "$id" recovery_cursor); _rcursor=${_rcursor:-0}
          _rterminal=$(printf '%s\n' "$_rplan" | awk -F'\t' '$1=="terminal"{print $2}')
          _rphase=$(jq -r '.phase // "unknown"' "$RUN/work/$id/status.json" 2>/dev/null || echo unknown)
          _routcome="RED:executor-crash"
          [ "$_rphase" = "done" ] && _routcome=$(_recovery_reverify "$id")
          if [ "${_routcome%%:*}" = "GREEN" ]; then
            if [ "$_rterminal" = "merge" ]; then
              # GREEN -> honor terminal=merge: hand back to the integrator to merge, clear recovery.
              sset "$id" kind ""; sset "$id" recovery_await ""; sset "$id" pid ""; sset "$id" term 1
              gh issue edit "$id" -R "$CB_REPO" \
                --remove-label status:needs-recovery --remove-label status:needs-rework \
                --add-label status:review >/dev/null 2>&1 || true
              log "#$id recovery: step $_rcursor GREEN, terminal=merge -> review (integrator merges)"
            else
              # GREEN but terminal=defer: do NOT merge — deferred (d).
              _recovery_terminal "$id" "step-$_rcursor-green-terminal-defer" "manager directive: defer (no merge)"
            fi
          else
            # RED -> advance cursor and dispatch the next step (or exhaustion -> deferred).
            log "#$id recovery: step $_rcursor RED (${_routcome#RED:}) -> advancing cursor"
            sset "$id" recovery_cursor "$((_rcursor + 1))"
            sset "$id" recovery_await ""
            sset "$id" pid ""
            _recovery_dispatch_step "$id"
          fi
          continue
        fi
        # kind=triage completion handler: triage agent finished; route leaf by verdict. (#784)
        if [ "$(sget "$id" kind)" = "triage" ]; then
          _tvrd=$(gh issue view "$id" -R "$CB_REPO" --json comments 2>/dev/null \
            | jq -r '[.comments[]?.body | select(contains("## Triage (machine)"))] | last // empty' \
            2>/dev/null || true)
          if [ -z "$_tvrd" ]; then
            # charter #1049 (a): triage returned NO verdict → escalate to the recovery-lead
            # (status:needs-recovery) INSTEAD of blocked, gated behind RED_REASON (#1110).
            sset "$id" triage_done "1"
            if _recovery_escalate "$id" "$(sget "$id" red_reason)"; then
              continue
            fi
            log "#$id kind=triage: no verdict comment found — routing to blocked"
            board route "$id" blocked "triage: no verdict found" >/dev/null
            sset "$id" pid ""; sset "$id" kind ""; sset "$id" term 1
            continue
          fi
          _ttsv=$(printf '%s\n' "$_tvrd" \
            | bash "${CB_TRIAGE_PARSE:-$HERE_LAUNCHER/triage-parse.sh}" 2>/dev/null) || {
            log "#$id kind=triage: verdict parse failed — routing to blocked"
            board route "$id" blocked "triage: verdict parse failed" >/dev/null
            sset "$id" pid ""; sset "$id" kind ""; sset "$id" triage_done "1"; sset "$id" term 1
            continue
          }
          _troot=$(printf '%s' "$_ttsv" | awk -F'\t' '$1=="root"{print $2}')
          _troute=$(printf '%s' "$_ttsv" | awk -F'\t' '$1=="route"{print $2}')
          _tevidence=$(printf '%s' "$_ttsv" | awk -F'\t' '$1=="evidence"{print $2}')
          log "#$id triage: root=$_troot route=$_troute"
          case "$_troute" in
            executor-rework|test-flaky)
              gh issue edit "$id" -R "$CB_REPO" --remove-label status:needs-triage >/dev/null 2>&1 || true
              board route "$id" requeue >/dev/null
              sset "$id" tries ""; log "#$id triage: $_troute -> requeue + tries cleared" ;;
            needs-plan)
              _tch=$(board get "$id" charter 2>/dev/null || true)
              gh issue edit "$id" -R "$CB_REPO" --remove-label status:needs-triage >/dev/null 2>&1 || true
              if [ -n "$_tch" ]; then
                recovery_n=$(sget "$_tch" recovery_n); recovery_n=${recovery_n:-0}
                if [ "$recovery_n" -ge "$CB_RECOVERY_CAP" ]; then
                  gh issue edit "$_tch" -R "$CB_REPO" \
                    --add-label status:deferred \
                    --remove-label status:approved \
                    --remove-label status:needs-plan \
                    --remove-label status:needs-analysis >/dev/null 2>&1 || true
                  gh issue comment "$_tch" -R "$CB_REPO" \
                    --body "deferred after ${recovery_n} cycles; root: ${_troot:-unknown}; last failure: ${_tevidence:-unknown}"
                  log "#$id triage: plan-flaw -> charter #$_tch deferred (recovery_n=$recovery_n >= CB_RECOVERY_CAP=$CB_RECOVERY_CAP)"
                else
                  sset "$_tch" recovery_n "$((recovery_n + 1))"
                  _thas_bounce=$(gh issue view "$_tch" -R "$CB_REPO" --json comments \
                    | jq -r '[.comments[]?.body | select(contains("<!-- triage-bounce -->"))] | length')
                  if [ "${_thas_bounce:-0}" = "0" ]; then
                    gh issue comment "$_tch" -R "$CB_REPO" --body "$(printf \
                      '<!-- triage-bounce -->\n**Bounce evidence** (root: %s, route: %s)\n\n```\n%s\n```' \
                      "$_troot" "$_troute" "$_tevidence")"
                  fi
                  gh issue edit "$_tch" -R "$CB_REPO" \
                    --remove-label status:approved --add-label status:needs-plan >/dev/null 2>&1 || true
                  log "#$id triage: plan-flaw -> charter #$_tch needs-plan"
                fi
              fi ;;
            needs-analysis)
              _tch=$(board get "$id" charter 2>/dev/null || true)
              gh issue edit "$id" -R "$CB_REPO" --remove-label status:needs-triage >/dev/null 2>&1 || true
              if [ -n "$_tch" ]; then
                recovery_n=$(sget "$_tch" recovery_n); recovery_n=${recovery_n:-0}
                if [ "$recovery_n" -ge "$CB_RECOVERY_CAP" ]; then
                  gh issue edit "$_tch" -R "$CB_REPO" \
                    --add-label status:deferred \
                    --remove-label status:approved \
                    --remove-label status:needs-plan \
                    --remove-label status:needs-analysis >/dev/null 2>&1 || true
                  gh issue comment "$_tch" -R "$CB_REPO" \
                    --body "deferred after ${recovery_n} cycles; root: ${_troot:-unknown}; last failure: ${_tevidence:-unknown}"
                  log "#$id triage: approach-flaw -> charter #$_tch deferred (recovery_n=$recovery_n >= CB_RECOVERY_CAP=$CB_RECOVERY_CAP)"
                else
                  sset "$_tch" recovery_n "$((recovery_n + 1))"
                  _thas_bounce=$(gh issue view "$_tch" -R "$CB_REPO" --json comments \
                    | jq -r '[.comments[]?.body | select(contains("<!-- triage-bounce -->"))] | length')
                  if [ "${_thas_bounce:-0}" = "0" ]; then
                    gh issue comment "$_tch" -R "$CB_REPO" --body "$(printf \
                      '<!-- triage-bounce -->\n**Bounce evidence** (root: %s, route: %s)\n\n```\n%s\n```' \
                      "$_troot" "$_troute" "$_tevidence")"
                  fi
                  gh issue edit "$_tch" -R "$CB_REPO" \
                    --remove-label status:approved --add-label status:needs-analysis >/dev/null 2>&1 || true
                  log "#$id triage: approach-flaw -> charter #$_tch needs-analysis"
                fi
              fi ;;
            test-bug)
              gh issue edit "$id" -R "$CB_REPO" \
                --remove-label status:needs-triage \
                --add-label status:test-broken \
                --add-label status:needs-rework >/dev/null 2>&1 || true
              log "#$id triage: test-bug -> needs-rework + test-broken" ;;
            infra)
              gh issue edit "$id" -R "$CB_REPO" --remove-label status:needs-triage >/dev/null 2>&1 || true
              board route "$id" blocked "triage: infra failure" >/dev/null
              log "#$id triage: infra -> blocked" ;;
            *)
              board route "$id" blocked "triage: unknown route: $_troute" >/dev/null
              log "#$id triage: unknown route '$_troute' -> blocked" ;;
          esac
          sset "$id" pid ""; sset "$id" kind ""; sset "$id" triage_done "1"; sset "$id" term 1
          continue
        fi
        ph=$(jq -r '.phase' "$RUN/work/$id/status.json" 2>/dev/null || echo unknown)
        case "$ph" in
          done)        board route "$id" review  >/dev/null; sset "$id" term 1; log "#$id done -> review" ;;
          budget-stop) board route "$id" requeue >/dev/null; stop=1; log "#$id budget -> requeue, STOP new claims" ;;
          *)           prev=$(sget "$id" tries); prev=${prev:-0}; tries=$((prev+1)); sset "$id" tries "$tries"
                       if [ "$tries" -ge "$RETRY_CAP" ]; then
                         if [ -n "${TRIAGE_SPAWN:-}" ] && [ -z "$(sget "$id" triage_done)" ]; then
                           board route "$id" needs-triage "executor failed $tries×" >/dev/null
                           sset "$id" kind "triage"
                           "$TRIAGE_SPAWN" "$id" &
                           sset "$id" pid "$!"
                           log "#$id failed($tries) -> needs-triage (triage spawned)"
                           continue
                         fi
                         board route "$id" blocked "executor failed $tries× (retry-cap $RETRY_CAP)" >/dev/null; sset "$id" term 1; log "#$id failed($tries) -> blocked"
                       else board route "$id" requeue >/dev/null; log "#$id failed($tries) -> requeue"; fi ;;
        esac
        sset "$id" pid ""
      done
      # integrator step: merge review-state leaves into charter/C (every tick, non-fatal)
      _integrator_cycle || log "integrator-cycle: error (continuing)"
      # test-quality gate step: after all leaves merged, check test quality before finale
      # (scoped execution only — no-op in multi-charter mode; bootstrap caveat #193)
      _tqg_cycle || log "tqg-cycle: error (continuing)"
      # charter finale step: for charters with all leaves closed, run local gate + draft PR
      _charter_finale_cycle || log "charter-finale-cycle: error (continuing)"
      running=$(running_count)
      # pause: keep managing in-flight spawns but claim NO new work until the flag is removed.
      if [ -f "$RUN/pause" ]; then
        log "paused — not claiming new (rm $RUN/pause to resume)"
      # claim new launchable up to the cap
      elif [ -z "$stop" ]; then
        # ── queue-mode detection (per tick) ──────────────────────────────────
        # Read $RUN/queue.json; if .order[] is non-empty, restrict new work to:
        #   _q_head      (leaf-execution head): first charter not in plan-review/done/blocked
        #   _q_plan_head (plan-conv head): first charter not in approved/done/blocked
        # Two heads allow plan-convergence to advance independently of leaf execution:
        # a charter in plan-review is NOT yet approved (its leaves are not launchable),
        # so _q_head skips it — but _q_plan_head targets it so the plan-conv gate fires.
        # Terminal-for-queue (_q_head): done, blocked, or plan-review that is genuinely a
        # human-park (no plan_review_role configured, OR plan:agreed already present). A
        # plan-review charter with plan_review_role AND without plan:agreed is non-terminal (#382).
        # Empty/absent/unreadable → no queue mode → normal behaviour.
        _q_order=$(jq -r '.order[]' "$RUN/queue.json" 2>/dev/null) || _q_order=""
        _q_head=""; _q_plan_head=""; _q_accept_head=""; _q_loo_set=""
        if [ -n "$_q_order" ]; then
          for _qn in $_q_order; do
            _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
            case "$_qst" in
              done|blocked|hold|deferred) continue ;;
              plan-review)
                # Skip plan-review only when terminal: no plan_review_role (human-park path)
                # or plan:agreed already set (convergence complete).
                _prr_q=$(manifest_policy "${CB_MANIFEST:-}" plan_review_role 2>/dev/null || true)
                if [ -z "$_prr_q" ]; then continue; fi
                _plag_q=$(gh issue view "$_qn" -R "$CB_REPO" --json labels 2>/dev/null \
                          | jq -r '[.labels[].name] | index("plan:agreed") != null' 2>/dev/null || echo "false")
                [ "$_plag_q" = "true" ] && continue
                ;;
            esac
            _q_head="$_qn"; break
          done
          for _qn in $_q_order; do
            _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
            case "$_qst" in approved|done|blocked|hold|deferred) continue ;; esac
            _q_plan_head="$_qn"; break
          done
          # _q_accept_head: first charter not in done/blocked state.
          # Do NOT skip charters with accept:agreed — they still need the acceptance-convergence
          # step (Change B) to remove the label and reset ci_state; excluding them strands the charter.
          for _qn in $_q_order; do
            _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
            case "$_qst" in done|blocked|hold|deferred) continue ;; esac
            _q_accept_head="$_qn"; break
          done
          # Build skip-aware lookahead eligibility set for analysis-cycle (charter #506).
          # Collects head + up to CB_QUEUE_LOOKAHEAD additional active entries
          # (skipping done|blocked|hold|deferred, same logic as _q_head computation).
          # Raw positional slicing of _q_order is explicitly prohibited — must be skip-aware.
          # When CB_QUEUE_LOOKAHEAD=0, the set contains only the active head → serial behaviour.
          _q_lookahead=${CB_QUEUE_LOOKAHEAD:-2}
          _q_loo_set=""
          _q_loo_count=0
          for _qn in $_q_order; do
            _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
            case "$_qst" in done|blocked|hold|deferred) continue ;; esac
            _q_loo_set="${_q_loo_set:+$_q_loo_set }${_qn}"
            _q_loo_count=$((_q_loo_count+1))
            [ "$_q_loo_count" -ge "$((_q_lookahead+1))" ] && break
          done
          _q_disp=$(printf '%s' "$_q_order" | tr '\n' ',' | sed 's/,$//')
          log "queue-mode: order=[$_q_disp] head=#${_q_head:-none} plan-head=#${_q_plan_head:-none} accept-head=#${_q_accept_head:-none} loo-set=[${_q_loo_set:-none}]"
        fi
        # bare-charter guard: if _q_head is a type:charter with no status:* label,
        # stamp status:needs-analysis so the analysis-cycle picks it up this tick.
        # Uses a fresh gh issue view call — _cid_labels is only set inside
        # plannable_scoped (line 1454) and is stale/uninitialized here.
        if [ -n "$_q_head" ]; then
          _q_head_labels=$(gh issue view "$_q_head" -R "$CB_REPO" --json labels 2>/dev/null \
            | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
          _qh_is_charter=$(printf '%s' "$_q_head_labels" \
            | jq -r 'any(.[]; . == "type:charter")' 2>/dev/null || echo "false")
          _qh_has_status=$(printf '%s' "$_q_head_labels" \
            | jq -r 'any(.[]; startswith("status:"))' 2>/dev/null || echo "false")
          if [ "$_qh_is_charter" = "true" ] && [ "$_qh_has_status" = "false" ]; then
            log "bare-charter guard: #$_q_head is type:charter with no status label — stamping status:needs-analysis"
            gh issue edit "$_q_head" -R "$CB_REPO" --add-label "status:needs-analysis" >/dev/null 2>&1 || true
          fi
        fi
        # analysis-cycle (manifest mode only): before tech-lead decomposition, charters
        # MUST pass through the analysis stage.  Re-entrant: matches needs-plan charters
        # WITHOUT composition:approved (analysis not yet done) AND needs-analysis charters
        # (restart/retry of a failed analysis spawn).  Charters WITH composition:approved
        # skip analysis and proceed to the plannable-scoped (tech-lead) path below.
        if [ -n "${CB_MANIFEST:-}" ]; then
          for cid in $(plannable_scoped); do
            [ "$running" -ge "$MAXP" ] && break
            # queue-mode: lookahead-eligible charters (head + up to CB_QUEUE_LOOKAHEAD) may run analysis
            if [ -n "$_q_order" ]; then
              [ -n "$_q_loo_set" ] || break
              case " $_q_loo_set " in *" $cid "*) : ;; *) continue ;; esac
            fi
            [ -n "$(sget "$cid" pid)" ] && continue
            [ -n "$(sget "$cid" term)" ] && continue
            # If composition:approved, skip analysis — go straight to tech-lead below
            _cid_labels=$(gh issue view "$cid" -R "$CB_REPO" --json labels \
                          2>/dev/null | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
            _comp_approved=$(printf '%s' "$_cid_labels" | jq -r 'index("composition:approved") != null' 2>/dev/null || echo "false")
            [ "$_comp_approved" = "true" ] && continue
            # Route needs-plan → needs-analysis (if not already in needs-analysis)
            cst=$(board get "$cid" state 2>/dev/null || echo "")
            if [ "$cst" = "needs-plan" ]; then
              board route "$cid" analysis >/dev/null
            elif [ "$cst" != "needs-analysis" ]; then
              continue
            fi
            # Get analysis role from manifest
            _analysis_role=$(manifest_analysis_roles "$CB_MANIFEST" | head -1)
            [ -n "$_analysis_role" ] || { log "#$cid no analysis_role in manifest — skip"; continue; }
            sset "$cid" kind analysis; sset "$cid" starttime "$(now)"
            ( "$ANALYSIS_SPAWN" "$cid" "$_analysis_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
            running=$((running+1))
            log "bg-spawn analysis ($_analysis_role) for charter #$cid (running=$running/$MAXP)"
          done
          # Also pick up needs-analysis charters that are NOT in plannable_scoped
          # (they already transitioned past needs-plan, so plannable_scoped won't list them)
          _analysis_boards=$(_cb_issue_list open 2>/dev/null | jq -r '
            .[] | select([.labels[].name] | index("type:charter") != null)
                | select([.labels[].name] | index("status:needs-analysis") != null)
                | select([.labels[].name] | index("hold") == null)
                | .number' 2>/dev/null || true)
          for cid in $_analysis_boards; do
            [ "$running" -ge "$MAXP" ] && break
            [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
            # queue-mode: lookahead-eligible charters (head + up to CB_QUEUE_LOOKAHEAD) may run analysis
            if [ -n "$_q_order" ]; then
              [ -n "$_q_loo_set" ] || break
              case " $_q_loo_set " in *" $cid "*) : ;; *) continue ;; esac
            fi
            [ -n "$(sget "$cid" pid)" ] && continue
            [ -n "$(sget "$cid" term)" ] && continue
            _analysis_role=$(manifest_analysis_roles "$CB_MANIFEST" | head -1)
            [ -n "$_analysis_role" ] || { log "#$cid no analysis_role in manifest — skip"; continue; }
            sset "$cid" kind analysis; sset "$cid" starttime "$(now)"
            ( "$ANALYSIS_SPAWN" "$cid" "$_analysis_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
            running=$((running+1))
            log "bg-spawn analysis (retry: $_analysis_role) for charter #$cid (running=$running/$MAXP)"
          done
          # approval-cycle: for charters in team-review (composition produced by analysis stage),
          # parse composition, estimate cost via HD-2, then either spawn approval_role (CTO) or
          # escalate to type:human-decision when est > threshold or no run history.
          _approval_role=$(manifest_policy "$CB_MANIFEST" approval_role 2>/dev/null || true)
          _approval_threshold=$(manifest_policy "$CB_MANIFEST" human_approval_above_usd 2>/dev/null || true)
          if [ -n "$_approval_role" ] && [ -n "$_approval_threshold" ]; then
            _tr_charters=$(_cb_issue_list open 2>/dev/null | jq -r '
              .[] | select([.labels[].name] | index("type:charter") != null)
                  | select([.labels[].name] | index("status:team-review") != null)
                  | select([.labels[].name] | index("hold") == null)
                  | .number' 2>/dev/null || true)
            for cid in $_tr_charters; do
              [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
              # queue-mode: only head charter is eligible for approval
              if [ -n "$_q_order" ]; then
                [ -z "$_q_head" ] && break
                [ "$cid" = "$_q_head" ] || continue
              fi
              [ -n "$(sget "$cid" pid)" ] && continue
              [ -n "$(sget "$cid" term)" ] && continue
              # a. Parse last ## Composition (machine) comment; exit≠0 → auto-reject to analysis
              _comp_body=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                2>/dev/null | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' 2>/dev/null || true)
              _comp_tsv=""
              if [ -n "$_comp_body" ]; then
                _comp_tsv=$(printf '%s\n' "$_comp_body" \
                  | bash "$HERE_LAUNCHER/composition-parse.sh" "$CB_MANIFEST" 2>/dev/null) || _comp_tsv=""
              fi
              if [ -z "$_comp_tsv" ]; then
                # FORMAT-reject cap (#334 runaway guard) on its OWN counter `fround`/CB_FORMAT_CAP (#352),
                # SEPARATE from substance `cround`/CONVERGE_CAP. A transient format-glitch mid-convergence
                # must NOT consume a substance-review round and prematurely escalate (the #350 finding).
                _fround=$(sget "$cid" fround); _fround=${_fround:-0}; _fcap="${CB_FORMAT_CAP:-${CB_CONVERGE_CAP:-4}}"
                if [ "$_fround" -ge "$_fcap" ]; then
                  _all_hd=$(_cb_issue_list open 2>/dev/null || echo "[]")
                  _ex_hd=$(printf '%s' "$_all_hd" | jq -r --argjson c "$cid" '[.[] | select([.labels[].name] | index("type:human-decision") != null) | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' 2>/dev/null || echo "0")
                  if [ "${_ex_hd:-0}" = "0" ]; then
                    _last_verdict=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                      2>/dev/null | jq -r '[.comments[] | select(.body | test("^(PLAN-REVIEW:|REVIEW:)"))] | last | .body // ""' 2>/dev/null || true)
                    gh issue create -R "$CB_REPO" \
                      --title "Human decision: charter #$cid composition not converging" \
                      --body "## Composition not converging

Charter #$cid composition stayed format-invalid through FORMAT_CAP=$_fcap rounds (analyst keeps producing an unparseable/invalid-role composition). Human call: fix the manifest/charter, give direction, or close.

Charter: #$cid

## Суть эскалации
Композиция не сошлась за $_fcap раундов

## Текущий план / состав
${_comp_body:-не удалось получить}

## Последний вердикт
${_last_verdict:-не удалось получить}

## Варианты действий
- Одобрить: команда approve-hd — разблокирует гейт, применяет нужные лейблы на чартере.
- На доработку: команда request-changes-hd — отклоняет без разблокировки, закрывает HD с причиной.
- Закрыть: команда close-hd — закрывает HD без изменений на чартере." \
                      --label "type:human-decision" 2>/dev/null || true
                  fi
                  log "#$cid composition cap $_fcap reached (format-invalid) → human-decision"
                  continue
                fi
                sset "$cid" fround "$((_fround+1))"
                log "#$cid approval-gate: invalid/missing composition (format round $((_fround+1))/$_fcap) → re-analysis"
                board route "$cid" analysis >/dev/null || true
                gh issue comment "$cid" -R "$CB_REPO" \
                  --body "approval-gate: composition block missing or invalid — routed back to needs-analysis (format round $((_fround+1))/$_fcap)" \
                  2>/dev/null || true
                continue
              fi
              # ── REVIEWER substance-convergence gate (#334) ──
              # Composition is format-valid; require code-grounded SUBSTANCE review before cost/cto.
              # analyst ↔ reviewer rounds until review:agreed; CONVERGE_CAP → escalate to human.
              _review_role=$(manifest_policy "$CB_MANIFEST" review_role 2>/dev/null || true)
              if [ -n "$_review_role" ]; then
                _rv_lbls=$(gh issue view "$cid" -R "$CB_REPO" --json labels 2>/dev/null | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
                _rv_agreed=$(printf '%s' "$_rv_lbls" | jq -r 'index("review:agreed") != null' 2>/dev/null || echo "false")
                if [ "$_rv_agreed" != "true" ]; then
                  _cround=$(sget "$cid" cround); _cround=${_cround:-0}
                  _ccap="${CB_CONVERGE_CAP:-4}"
                  if [ "$_cround" -ge "$_ccap" ]; then
                    _all_hd=$(_cb_issue_list open 2>/dev/null || echo "[]")
                    _ex_hd=$(printf '%s' "$_all_hd" | jq -r --argjson c "$cid" '[.[] | select([.labels[].name] | index("type:human-decision") != null) | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' 2>/dev/null || echo "0")
                    if [ "${_ex_hd:-0}" = "0" ]; then
                      _last_verdict=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                        2>/dev/null | jq -r '[.comments[] | select(.body | test("^(PLAN-REVIEW:|REVIEW:)"))] | last | .body // ""' 2>/dev/null || true)
                      gh issue create -R "$CB_REPO" \
                        --title "Human decision: charter #$cid analysis did not converge" \
                        --body "## Convergence not reached

Charter #$cid did not reach review agreement within CONVERGE_CAP=$_ccap rounds. Human call: approve the latest composition, give direction, or close.

Charter: #$cid

## Суть эскалации
Анализ не сошёлся за $_ccap раундов

## Текущий план / состав
${_comp_body:-не удалось получить}

## Последний вердикт
${_last_verdict:-не удалось получить}

## Варианты действий
- Одобрить: команда approve-hd — разблокирует гейт, применяет нужные лейблы на чартере.
- На доработку: команда request-changes-hd — отклоняет без разблокировки, закрывает HD с причиной.
- Закрыть: команда close-hd — закрывает HD без изменений на чартере." \
                        --label "type:human-decision" 2>/dev/null || true
                      log "#$cid convergence: cap $_ccap reached → human-decision"
                    fi
                    continue
                  fi
                  [ "$running" -ge "$MAXP" ] && break
                  sset "$cid" kind review; sset "$cid" cround "$((_cround+1))"; sset "$cid" starttime "$(now)"
                  ( "$REVIEW_SPAWN" "$cid" "$_review_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
                  running=$((running+1))
                  log "bg-spawn review ($_review_role) round $((_cround+1)) for charter #$cid (running=$running/$MAXP)"
                  continue
                fi
              fi
              # b. HD-2 cost estimate: (spent_usd / len(runs)) × leaf_count
              _leaf_count=$(printf '%s\n' "$_comp_tsv" | awk -F'\t' '$1=="leaf"' | wc -l | tr -d '[:space:]')
              _budget_file="$RUN/budget.json"
              _est_cost=""
              _no_hist=1
              if [ -f "$_budget_file" ]; then
                _bspent=$(jq -r '.spent_usd // 0' "$_budget_file" 2>/dev/null || echo "0")
                _brun_count=$(jq -r '.runs | length // 0' "$_budget_file" 2>/dev/null || echo "0")
                if [ "${_brun_count:-0}" -gt 0 ]; then
                  _no_hist=0
                  if [ "${_leaf_count:-0}" -gt 0 ]; then
                    _avg=$(awk "BEGIN{printf \"%.6f\", ${_bspent:-0} / ${_brun_count}}")
                    _est_cost=$(awk "BEGIN{printf \"%.6f\", $_avg * $_leaf_count}")
                  else
                    _est_cost="0"
                  fi
                fi
              fi
              # c. Escalate if no history OR est > threshold → create type:human-decision (idempotent)
              _escalate=0
              if [ "$_no_hist" = "1" ]; then
                _escalate=1
                log "#$cid approval-gate: no budget history → escalate to human-decision"
              elif awk "BEGIN{exit ($_est_cost > $_approval_threshold) ? 0 : 1}" 2>/dev/null; then
                _escalate=1
                log "#$cid approval-gate: est \$$_est_cost > threshold \$$_approval_threshold → escalate"
              fi
              if [ "$_escalate" = "1" ]; then
                # Idempotent: only one open human-decision per charter (check by body text)
                _all_hd=$(_cb_issue_list open 2>/dev/null || echo "[]")
                _existing_hd=$(printf '%s' "$_all_hd" | jq -r --argjson c "$cid" '
                  [.[] | select([.labels[].name] | index("type:human-decision") != null)
                        | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))]
                  | length' 2>/dev/null || echo "0")
                if [ "${_existing_hd:-0}" = "0" ]; then
                  _leaf_lines=$(printf '%s\n' "$_comp_tsv" | awk -F'\t' '$1=="leaf"{printf "- leaf: %s -> %s\n",$2,$3}' || true)
                  _last_verdict=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                    2>/dev/null | jq -r '[.comments[] | select(.body | test("^(PLAN-REVIEW:|REVIEW:)"))] | last | .body // ""' 2>/dev/null || true)
                  _hd_body="## Human Approval Required

Charter #$cid requires human approval before the composition can proceed.

## Composition
$_leaf_lines

## Cost Estimate (HD-2)
- Estimated cost: \$${_est_cost:-unknown}
- Threshold: \$$_approval_threshold
- Decision: over-threshold or no run history (conservative escalation)

Charter: #$cid

## Суть эскалации
Требуется одобрение человека перед началом работ

## Текущий план / состав
${_comp_body:-не удалось получить}

## Последний вердикт
${_last_verdict:-не удалось получить}

## Варианты действий
- Одобрить: команда approve-hd — разблокирует гейт, применяет нужные лейблы на чартере.
- На доработку: команда request-changes-hd — отклоняет без разблокировки, закрывает HD с причиной.
- Закрыть: команда close-hd — закрывает HD без изменений на чартере."
                  gh issue create -R "$CB_REPO" \
                    --title "Human approval required: Charter #$cid" \
                    --body "$_hd_body" \
                    --label "type:human-decision" \
                    2>/dev/null || true
                  log "#$cid approval-gate: human-decision issue created"
                else
                  log "#$cid approval-gate: human-decision already open (idempotent) — skip"
                fi
                # Charter remains in team-review; N-1: open human-decision → loop does NOT hold alive
                continue
              fi
              # d. est ≤ threshold → bg-spawn approval_role
              [ "$running" -ge "$MAXP" ] && break
              sset "$cid" kind approval; sset "$cid" starttime "$(now)"
              ( "$APPROVAL_SPAWN" "$cid" "$_approval_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
              running=$((running+1))
              log "bg-spawn approval ($_approval_role) for charter #$cid (running=$running/$MAXP)"
            done
          fi
        fi
        # conflict-resolution cycle: for charters with status:needs-conflict-resolution,
        # spawn git-resolver to resolve merge conflicts so the finale can proceed. [#187 L2]
        _conflict_boards=$(_cb_issue_list open 2>/dev/null | jq -r '
          .[] | select([.labels[].name] | index("type:charter") != null)
              | select([.labels[].name] | index("status:needs-conflict-resolution") != null)
              | select([.labels[].name] | index("hold") == null)
              | .number' 2>/dev/null || true)
        for cid in $_conflict_boards; do
          [ "$running" -ge "$MAXP" ] && break
          [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
          # queue-mode: only head charter is eligible for conflict-resolution
          if [ -n "$_q_order" ]; then
            [ -z "$_q_head" ] && break
            [ "$cid" = "$_q_head" ] || continue
          fi
          [ -n "$(sget "$cid" pid)" ] && continue
          [ -n "$(sget "$cid" term)" ] && continue
          sset "$cid" kind conflict-resolution; sset "$cid" starttime "$(now)"
          ( "$CONFLICT_SPAWN" "$cid" git-resolver >/dev/null 2>&1 ) & sset "$cid" pid "$!"
          running=$((running+1))
          log "bg-spawn git-resolver for charter #$cid (running=$running/$MAXP)"
        done
        # blast-radius gate (unscoped only): if a high-blast-radius charter is active,
        # hold all other charters and only dispatch work for it. [#262]
        _block=""
        [ "${CHARTER_SCOPE:-0}" = "0" ] && _block=$(_serializing_charter)
        [ -n "$_block" ] && log "blast-radius: serializing on #$_block — other charters held"
        # plan charters first: a needs-plan charter -> spawn a tech-lead to decompose it
        # (it sets the charter to plan-review itself; local pid guard prevents double-spawn).
        for cid in $(plannable_scoped); do
          [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
          # queue-mode: only head charter is eligible for tech-lead planning
          if [ -n "$_q_order" ]; then
            [ -z "$_q_head" ] && break
            [ "$cid" = "$_q_head" ] || continue
          fi
          [ "$running" -ge "$MAXP" ] && break
          [ -n "$(sget "$cid" pid)" ] && continue
          [ -n "$(sget "$cid" term)" ] && continue
          sset "$cid" kind charter; sset "$cid" starttime "$(now)"
          ( "$PLAN_SPAWN" "$cid" tech-lead >/dev/null 2>&1 ) & sset "$cid" pid "$!"
          running=$((running+1)); log "bg-spawn tech-lead for charter #$cid (running=$running/$MAXP)"
        done
        # ── PLAN-convergence gate (#382): after tech-lead plans (plan-review), the analyst reviews
        # the PLAN before execution. tech-lead ↔ analyst rounds until plan:agreed; CB_PLAN_CONVERGE_CAP
        # → escalate. plan:agreed → status:approved (release leaves). Mirror of the #334 composition gate.
        _plan_review_role=$(manifest_policy "${CB_MANIFEST:-}" plan_review_role 2>/dev/null || true)
        if [ -n "$_plan_review_role" ]; then
          _plr_charters=$(_cb_issue_list open 2>/dev/null | jq -r '
            .[] | select([.labels[].name] | index("type:charter") != null)
                | select([.labels[].name] | index("status:plan-review") != null)
                | select([.labels[].name] | index("hold") == null)
                | .number' 2>/dev/null || true)
          for cid in $_plr_charters; do
            [ "$running" -ge "$MAXP" ] && break
            [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
            [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
            if [ -n "$_q_order" ]; then [ -z "$_q_plan_head" ] && break; [ "$cid" = "$_q_plan_head" ] || continue; fi
            [ -n "$(sget "$cid" pid)" ] && continue
            [ -n "$(sget "$cid" term)" ] && continue
            _plr_labels_json=$(gh issue view "$cid" -R "$CB_REPO" --json labels 2>/dev/null \
              | jq -r '[.labels[].name]' 2>/dev/null || echo "[]")
            _plr_agreed=$(printf '%s' "$_plr_labels_json" | jq -r 'index("plan:agreed") != null' 2>/dev/null || echo "false")
            if [ "$_plr_agreed" = "true" ]; then
              gh issue edit "$cid" -R "$CB_REPO" --remove-label status:plan-review --add-label status:approved 2>/dev/null || true
              sset "$cid" term 1
              log "#$cid plan:agreed → status:approved (leaves released)"
              continue
            fi
            _pround=$(sget "$cid" pround); _pround=${_pround:-0}
            _charter_pcap_label=$(printf '%s' "$_plr_labels_json" \
              | jq -r '.[] | select(startswith("converge-cap:")) | ltrimstr("converge-cap:")' \
              | head -1)
            _pcap="${_charter_pcap_label:-${CB_PLAN_CONVERGE_CAP:-${CB_CONVERGE_CAP:-6}}}"
            if [ "$_pround" -ge "$_pcap" ]; then
              _all_hd=$(_cb_issue_list open 2>/dev/null || echo "[]")
              _ex_hd=$(printf '%s' "$_all_hd" | jq -r --argjson c "$cid" '[.[] | select([.labels[].name] | index("type:human-decision") != null) | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' 2>/dev/null || echo "0")
              if [ "${_ex_hd:-0}" = "0" ]; then
                _fresh_comp=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                  2>/dev/null | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' 2>/dev/null || true)
                _last_verdict=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                  2>/dev/null | jq -r '[.comments[] | select(.body | test("^(PLAN-REVIEW:|REVIEW:)"))] | last | .body // ""' 2>/dev/null || true)
                gh issue create -R "$CB_REPO" \
                  --title "Human decision: charter #$cid plan did not converge" \
                  --body "## Plan convergence not reached

Charter #$cid plan did not reach plan:agreed within CB_PLAN_CONVERGE_CAP=$_pcap rounds. Human call: approve the plan, give direction, or close.

Charter: #$cid

## Суть эскалации
План не сошёлся за $_pcap раундов

## Текущий план / состав
${_fresh_comp:-не удалось получить}

## Последний вердикт
${_last_verdict:-не удалось получить}

## Варианты действий
- Одобрить: команда approve-hd — разблокирует гейт, применяет нужные лейблы на чартере.
- На доработку: команда request-changes-hd — отклоняет без разблокировки, закрывает HD с причиной.
- Закрыть: команда close-hd — закрывает HD без изменений на чартере." \
                  --label "type:human-decision" 2>/dev/null || true
                log "#$cid plan-convergence: cap $_pcap reached → human-decision"
              fi
              continue
            fi
            [ "$running" -ge "$MAXP" ] && break
            sset "$cid" kind plan-review; sset "$cid" pround "$((_pround+1))"; sset "$cid" starttime "$(now)"
            ( CB_PLAN_REVIEW=1 "$PLAN_REVIEW_SPAWN" "$cid" "$_plan_review_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
            running=$((running+1))
            log "bg-spawn plan-review ($_plan_review_role) round $((_pround+1)) for charter #$cid (running=$running/$MAXP)"
          done
        fi
        # ── PLAN-limbo reconcile (#957): idempotent catch-all for charters that reached
        # plan:agreed + composition:approved WITHOUT status:plan-review being present.
        # Root-cause: the gate above (line 1736) filters by status:plan-review; if that label
        # was removed between the plan-reviewer AGREE round and the next tick (e.g. by an
        # external actor or a race with the critique/re-plan cycle), the existing gate silently
        # skips the charter and it hangs in limbo forever.  This block is the safety net.
        # Documented root-cause traces:
        #   • line 1225: leaf-count gate (RETRY_CAP reached) removes status:plan-review then
        #     calls `board route` to set status:blocked atomically — no ambiguity, no fix needed.
        #   • line 1231: leaf-count gate (retry) removes status:plan-review + adds
        #     status:needs-plan atomically — no fix needed.
        #   • plan-reviewer CRITIQUE path: removes status:plan-review + adds status:needs-plan
        #     atomically.  On the final AGREE round it adds plan:agreed but leaves status:plan-review
        #     in place so the gate above catches it.  Edge case: if anything external removes
        #     status:plan-review between the AGREE and the next loop tick, plan:agreed +
        #     composition:approved are both present but neither gate fires — this block catches it.
        if [ -n "$_plan_review_role" ]; then
          _limbo_charters=$(_cb_issue_list open 2>/dev/null | jq -r '
            .[] | select([.labels[].name] | index("type:charter") != null)
                | select([.labels[].name] | index("plan:agreed") != null)
                | select([.labels[].name] | index("composition:approved") != null)
                | select([.labels[].name] | index("status:approved") == null)
                | select([.labels[].name] | index("status:blocked") == null)
                | select([.labels[].name] | index("hold") == null)
                | .number' 2>/dev/null || true)
          for cid in $_limbo_charters; do
            [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
            [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
            if [ -n "$_q_order" ]; then [ -z "$_q_plan_head" ] && break; [ "$cid" = "$_q_plan_head" ] || continue; fi
            [ -n "$(sget "$cid" pid)" ] && continue
            [ -n "$(sget "$cid" term)" ] && continue
            gh issue edit "$cid" -R "$CB_REPO" --remove-label status:plan-review --add-label status:approved 2>/dev/null || true
            sset "$cid" term 1
            log "#$cid plan:agreed → status:approved (leaves released)"
          done
        fi
        # ── ACCEPTANCE-convergence gate (#522): after finale CI green + CB_AUTO_MERGE, the
        # acceptance-reviewer reviews before the charter merges to main.  acceptance_review_role
        # in manifest → active; mirrors plan-convergence (#382). accept:agreed → release to merge.
        _acc_review_role=$(manifest_policy "${CB_MANIFEST:-}" acceptance_review_role 2>/dev/null || true)
        if [ -n "$_acc_review_role" ]; then
          _acr_charters=$(_cb_issue_list open 2>/dev/null | jq -r '
            .[] | select([.labels[].name] | index("type:charter") != null)
                | select([.labels[].name] | index("status:acceptance-review") != null)
                | select([.labels[].name] | index("hold") == null)
                | .number' 2>/dev/null || true)
          for cid in $_acr_charters; do
            [ "$running" -ge "$MAXP" ] && break
            [ "${CHARTER_SCOPE:-0}" = "0" ] || [ "$cid" = "$CHARTER_SCOPE" ] || continue
            [ -n "$_block" ] && [ "$cid" != "$_block" ] && continue
            if [ -n "$_q_order" ]; then [ -z "$_q_accept_head" ] && break; [ "$cid" = "$_q_accept_head" ] || continue; fi
            [ -n "$(sget "$cid" pid)" ] && continue
            [ -n "$(sget "$cid" term)" ] && continue
            _acr_agreed=$(gh issue view "$cid" -R "$CB_REPO" --json labels 2>/dev/null \
              | jq -r '[.labels[].name] | index("accept:agreed") != null' 2>/dev/null || echo "false")
            if [ "$_acr_agreed" = "true" ]; then
              # Convergence complete: remove label and reset ci_state to pending so the charter-finale
              # cycle re-polls CI; on re-poll green, Change A sees accept:agreed and falls through to merge.
              gh issue edit "$cid" -R "$CB_REPO" --remove-label status:acceptance-review 2>/dev/null || true
              local _acr_fin_dir="$STATE/finale-$cid"
              mkdir -p "$_acr_fin_dir"
              printf '%s' "pending" > "$_acr_fin_dir/ci_state"
              sset "$cid" aound 0
              log "#$cid accept:agreed → acceptance-convergence complete (ci_state reset to pending for merge)"
              continue
            fi
            _aound=$(sget "$cid" aound); _aound=${_aound:-0}
            _acap="${CB_ACCEPT_CONVERGE_CAP:-${CB_CONVERGE_CAP:-4}}"
            if [ "$_aound" -ge "$_acap" ]; then
              _all_hd=$(_cb_issue_list open 2>/dev/null || echo "[]")
              _ex_hd=$(printf '%s' "$_all_hd" | jq -r --argjson c "$cid" '[.[] | select([.labels[].name] | index("type:human-decision") != null) | select((.body//"") | test("Charter:\\s*#?" + ($c|tostring)))] | length' 2>/dev/null || echo "0")
              if [ "${_ex_hd:-0}" = "0" ]; then
                _fresh_comp=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                  2>/dev/null | jq -r '[.comments[] | select(.body | contains("## Composition (machine)"))] | last | .body // ""' 2>/dev/null || true)
                _last_verdict=$(gh issue view "$cid" -R "$CB_REPO" --json comments \
                  2>/dev/null | jq -r '[.comments[] | select(.body | test("^(PLAN-REVIEW:|REVIEW:)"))] | last | .body // ""' 2>/dev/null || true)
                gh issue create -R "$CB_REPO" \
                  --title "Human decision: charter #$cid acceptance did not converge" \
                  --body "## Acceptance convergence not reached

Charter #$cid did not reach accept:agreed within CB_ACCEPT_CONVERGE_CAP=$_acap rounds. Human call: approve acceptance, give direction, or close.

Charter: #$cid

## Суть эскалации
Приёмка не сошлась за $_acap раундов

## Текущий план / состав
${_fresh_comp:-не удалось получить}

## Последний вердикт
${_last_verdict:-не удалось получить}

## Варианты действий
- Одобрить: команда approve-hd — разблокирует гейт, применяет нужные лейблы на чартере.
- На доработку: команда request-changes-hd — отклоняет без разблокировки, закрывает HD с причиной.
- Закрыть: команда close-hd — закрывает HD без изменений на чартере." \
                  --label "type:human-decision" 2>/dev/null || true
                log "#$cid acceptance-convergence: cap $_acap reached → human-decision"
              fi
              continue
            fi
            sset "$cid" aound "$((_aound+1))"; sset "$cid" kind acceptance-review; sset "$cid" starttime "$(now)"
            ( CB_ACCEPTANCE_REVIEW=1 "$ACCEPT_REVIEW_SPAWN" "$cid" "$_acc_review_role" >/dev/null 2>&1 ) & sset "$cid" pid "$!"
            running=$((running+1))
            log "bg-spawn acceptance-review ($_acc_review_role) round $((_aound+1)) for charter #$cid (running=$running/$MAXP)"
          done
        fi
        for id in $(board launchable); do
          [ "$running" -ge "$MAXP" ] && break
          # local authority over gh read-after-write lag: never re-handle an id that is
          # already in flight (pid set) or already terminal this run (term set), even if the
          # (laggy) gh list still reports it launchable.
          [ -n "$(sget "$id" pid)" ] && continue
          [ -n "$(sget "$id" term)" ] && continue
          [ -n "$_block" ] && [ "$(board get "$id" charter 2>/dev/null)" != "$_block" ] && continue
          # queue-mode filter: only the head charter's leaves are eligible
          if [ -n "$_q_order" ]; then
            if [ -z "$_q_head" ]; then break; fi
            _id_ch=$(board get "$id" charter 2>/dev/null || echo "")
            [ "$_id_ch" = "$_q_head" ] || continue
          fi
          # Choose spawn path before claiming (needs-rework -> rework script)
          _bg_spawn="$SPAWN"
          _bg_old_branch=""
          if [ "$(board get "$id" state)" = "needs-rework" ]; then
            _bg_spawn="$REWORK_SPAWN"
            _bg_old_branch="$(sget "$id" pr_head)"
          fi
          board claim "$id" "$LID" >/dev/null; sset "$id" starttime "$(now)"
          # charter #1049: preserve kind=recovery across a recovery step's re-claim so the
          # cross-TICK recovery handler still catches this executor when it finishes.
          [ "$(sget "$id" kind)" = "recovery" ] || sset "$id" kind "$(board get "$id" role)"
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
    ) {lockfd}>&-
  )
}

case "${1:-once}" in
  reconcile) ( exec {lockfd}>"$LOCK"; flock -n "$lockfd" || { log locked; exit 1; }; ( reconcile ) {lockfd}>&- ) ;;
  once) cmd_once ;;
  run)  cmd_run ;;
  re-dispatch) cmd_redispatch "${2:-}" ;;
  *) echo "usage: $0 {once|run|reconcile|re-dispatch <leaf-id>}"; exit 64 ;;
esac
