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
board(){ bash "$BOARD" "$@"; }
# plannable_scoped: when CREWBOSS_CHARTER is set, restrict plannable output to that charter only.
plannable_scoped(){
  if [ "${CHARTER_SCOPE:-0}" = "0" ]; then
    board plannable
  else
    board plannable | grep "^${CHARTER_SCOPE}$" || true
  fi
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
  local id="$1" role spawn_cmd
  role=$(board get "$id" role)
  # Choose spawn path before claiming: needs-rework -> rework script, otherwise normal.
  if [ "$(board get "$id" state)" = "needs-rework" ]; then
    spawn_cmd="$REWORK_SPAWN"
    log "claim #$id state=needs-rework -> rework path"
  else
    spawn_cmd="$SPAWN"
  fi
  board claim "$id" "$LID" >/dev/null   # also strips status:needs-rework (lifecycle)
  sset "$id" pid "$$"; sset "$id" starttime "$(now)"
  log "claim #$id role=$role (pid $$)"
  "$spawn_cmd" "$id" "$role"; local ex=$?
  route "$id" "$ex"
}

# ── integrator cycle: merge review-state leaf PRs into charter/C ─────────────
# Called every tick of cmd_run after finished-spawn routing.
# GREEN-BEFORE-MERGE: CI (statusCheckRollup) must be success before any merge.
# Idempotent: merged/closed leaves not re-processed.  All errors logged, non-fatal.
_integrator_cycle(){
  [ -n "$GIT_REMOTE" ]        || return 0
  [ -x "$INTEGRATOR_SCRIPT" ] || { log "integrator: script not found: $INTEGRATOR_SCRIPT"; return 0; }

  local review_ids
  review_ids=$(board review-leaves 2>/dev/null || true)
  [ -n "$review_ids" ] || return 0

  local open_prs="" merged_prs="" rid pr_head pr_num pr_base ci_json ci_status conflict_files try_ok
  local merge_sha="" file_list="" merge_rc=0 close_rc=0 pr_state="" rec_num="" rec_sha_r="" rec_rc=0

  # Snapshot open PRs once per cycle; match leaves by headRefName prefix leaf/<rid>-
  open_prs=$(gh pr list -R "$CB_REPO" --state open \
             --json number,headRefName,baseRefName 2>/dev/null || true)
  # Snapshot merged PRs once per cycle — needed for reconcile after a mid-run restart
  # (leaf stays in status:review but PR is already merged; no open PR exists).
  merged_prs=$(gh pr list -R "$CB_REPO" --state merged \
               --json number,headRefName,baseRefName 2>/dev/null || true)

  for rid in $review_ids; do
    # Skip leaves already merged this run (prevents double-merge)
    [ "$(sget "$rid" int_done)" = "merged" ] && continue

    # Find the open PR: headRefName must start with leaf/$rid- AND base must be charter/*
    pr_head=$(printf '%s' "$open_prs" | jq -r --arg rid "$rid" \
      '.[] | select(.headRefName | startswith("leaf/\($rid)-"))
           | select(.baseRefName | startswith("charter/"))
           | .headRefName' 2>/dev/null | head -1 || true)
    pr_num=$(printf '%s' "$open_prs" | jq -r --arg rid "$rid" \
      '.[] | select(.headRefName | startswith("leaf/\($rid)-"))
           | select(.baseRefName | startswith("charter/"))
           | .number' 2>/dev/null | head -1 || true)
    pr_base=$(printf '%s' "$open_prs" | jq -r --arg rid "$rid" \
      '.[] | select(.headRefName | startswith("leaf/\($rid)-"))
           | select(.baseRefName | startswith("charter/"))
           | .baseRefName' 2>/dev/null | head -1 || true)

    if [ -z "$pr_num" ]; then
      # No open PR — check if already MERGED (reconcile: leaf survived a launcher restart
      # mid-run, or close-leaf failed on a previous tick after a successful merge).
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
      log "integrator: #$rid in review but no open PR — skip"
      continue
    fi
    case "$pr_base" in
      charter/[0-9]*)  ;;
      *) log "integrator: #$rid PR #$pr_num base='$pr_base' not charter/* — skip"; continue ;;
    esac

    # ── GREEN-BEFORE-MERGE: CI must be success ────────────────────────────────
    ci_json=$(gh pr view "$pr_num" -R "$CB_REPO" --json statusCheckRollup \
              2>/dev/null || echo '{"statusCheckRollup":[]}')
    ci_status=$(printf '%s' "$ci_json" | jq -r '
      if (.statusCheckRollup | length) == 0 then "pending"
      elif (.statusCheckRollup | all(.conclusion == "SUCCESS" or .conclusion == "SKIPPED")) then "success"
      elif (.statusCheckRollup | any(.status == "IN_PROGRESS" or .status == "QUEUED")) then "pending"
      elif (.statusCheckRollup | any(.conclusion == null or .conclusion == "")) then "pending"
      else "failure" end' 2>/dev/null) || ci_status="failure"

    case "$ci_status" in
      pending)  log "integrator: #$rid PR #$pr_num CI pending — wait next tick"; continue ;;
      failure)  log "integrator: #$rid PR #$pr_num CI failed — not merging"; continue ;;
      success)  ;;
      *)        log "integrator: #$rid PR #$pr_num CI='$ci_status' unknown — skip"; continue ;;
    esac

    # ── try-merge dry-run ─────────────────────────────────────────────────────
    try_ok=true
    if ! conflict_files=$(bash "$INTEGRATOR_SCRIPT" try-merge "$pr_head" "$pr_base" \
                          --remote "$GIT_REMOTE" 2>/dev/null); then
      try_ok=false
    fi

    if [ "$try_ok" = "true" ]; then
      # Clean: merge PR → verify MERGED → close leaf → set int_done (all-or-nothing).
      # Any failure aborts the sequence; next tick retries from the appropriate step.
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
      else
        # Merge is done but close failed: next tick will find PR in merged_prs and
        # retry close-leaf via the reconcile path (idempotent; no double-merge risk).
        log "integrator: #$rid close-leaf FAILED (rc=$close_rc) — int_done NOT set; retry next tick"
      fi
    else
      # Conflict: route needs-rework so rework-spawn can rebase
      file_list=$(printf '%s' "$conflict_files" | head -5 | tr '\n' ' ' | sed 's/ *$//')
      [ -z "$file_list" ] && file_list="(unknown)"
      log "integrator: #$rid PR #$pr_num merge conflict: $file_list — needs-rework"
      board route "$rid" needs-rework "Merge conflict in: $file_list" >/dev/null || true
      # Clear terminal flag so rework-spawn can re-claim this leaf
      sset "$rid" term ""
    fi
  done
}

# ── charter finale: wait for CI checks on an existing draft PR and promote if green ──
# Called by _charter_finale_cycle after a draft PR is created (or already exists).
# Exit 0 = CI green (PR promoted); exit 1 = CI failed; exit 2 = timeout.
_finale_check_ci(){
  local cid="$1" pr_num="$2"
  local timeout="${CB_FINALE_CHECKS_TIMEOUT:-300}"
  local poll="${CB_FINALE_CHECKS_POLL:-15}"
  local deadline
  deadline=$(( $(date +%s) + timeout ))

  while :; do
    local checks_out checks_rc=0
    checks_out=$(gh pr checks "$pr_num" -R "$CB_REPO" 2>&1) || checks_rc=$?

    if [ "$checks_rc" -eq 0 ]; then
      log "charter-finale: #$cid PR #$pr_num CI green → promoting to ready"
      gh pr ready "$pr_num" -R "$CB_REPO" 2>/dev/null || true
      gh issue comment "$cid" -R "$CB_REPO" \
        --body "charter-finale: PR #$pr_num (charter/$cid → main) CI green — ready for human review" \
        2>/dev/null || true
      return 0
    fi

    # Definitive failure (output doesn't suggest still-pending)
    if ! printf '%s' "$checks_out" | grep -qi "pending\|in.progress\|queued"; then
      log "charter-finale: #$cid PR #$pr_num CI failed — stays draft"
      gh issue comment "$cid" -R "$CB_REPO" \
        --body "charter-finale: PR #$pr_num (charter/$cid → main) CI failed — stays draft" \
        2>/dev/null || true
      return 1
    fi

    # Still pending — respect timeout
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "charter-finale: #$cid PR #$pr_num CI check timeout (${timeout}s) — stays draft"
      gh issue comment "$cid" -R "$CB_REPO" \
        --body "charter-finale: PR #$pr_num (charter/$cid → main) CI check timeout — stays draft" \
        2>/dev/null || true
      return 2
    fi

    sleep "$poll"
  done
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
  [ -n "$GIT_REMOTE" ] || return 0
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

    # Condition: ALL leaves (non-charter issues mentioning Charter: #C) are CLOSED
    local open_leaf_count
    open_leaf_count=$(printf '%s' "$all_issues" | jq -r --argjson c "$cid" '
      [ .[] | select(.state == "OPEN")
             | select(([.labels[].name] | any(. == "type:charter")) | not)
             | select((.body // "") | test("(?i)Charter:\\s*#?" + ($c|tostring)))
      ] | length' 2>/dev/null) || open_leaf_count=1
    [ "$open_leaf_count" = "0" ] || continue

    # Condition: charter/C branch exists on the remote and is ahead of main
    local branch="charter/$cid"
    git ls-remote --exit-code --heads "$GIT_REMOTE" "$branch" >/dev/null 2>&1 || continue
    local b_sha m_sha
    b_sha=$(git ls-remote "$GIT_REMOTE" "refs/heads/$branch" 2>/dev/null | awk '{print $1}' | head -1)
    m_sha=$(git ls-remote "$GIT_REMOTE" "refs/heads/main"    2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$b_sha" ] && [ "$b_sha" != "$m_sha" ] || continue

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
    local gate_repo_dir="${CB_GATE_REPO_DIR:-.}"
    local gate_out gate_rc=0
    gate_out=$(bash "$INTEGRATOR_SCRIPT" gate-charter "$cid" \
                    "${harness_args[@]+"${harness_args[@]}"}" \
                    --repo-dir "$gate_repo_dir" 2>&1) || gate_rc=$?

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
          ( "$SPAWN" "$cid" tech-lead >/dev/null 2>&1 ) & sset "$cid" pid "$!"
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
          [ "$(board get "$id" state)" = "needs-rework" ] && _bg_spawn="$REWORK_SPAWN"
          board claim "$id" "$LID" >/dev/null; sset "$id" starttime "$(now)"
          ( "$_bg_spawn" "$id" "$(board get "$id" role)" >/dev/null 2>&1 ) & sset "$id" pid "$!"
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
      if [ "$running" -eq 0 ] && [ "$fresh" -eq 0 ]; then
        idle_ticks=$((idle_ticks+1))
        [ "$idle_ticks" -ge "${CB_IDLE_CONFIRM:-2}" ] && { log "idle — run complete"; break; }
      else idle_ticks=0; fi
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
