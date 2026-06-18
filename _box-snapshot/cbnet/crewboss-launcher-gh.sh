#!/usr/bin/env bash
# crewboss-launcher-gh.sh — launcher loop driving the REAL GitHub board via board-gh.sh.
# Same state machine as the local-JSON launcher (5b), but canonical state lives in gh
# labels; run-state (pid/starttime/tries) stays launcher-local under run/state/<id>/ (§9).
# SPAWN is overridable ($CB_SPAWN) so the loop is testable with a stub against synthetic
# gh issues — no jail, no spend.
#
# Subcommands: reconcile | once     Env: CB_REPO (req), CB_HOME, CB_SPAWN, CB_RETRY_CAP,
#                                        CB_MAX_PARALLEL, CB_LAUNCHER_ID
set -uo pipefail
: "${CB_REPO:?set CB_REPO=owner/repo}"; export CB_REPO
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"; STATE="$RUN/state"; LOCK="$RUN/launcher.lock"
RETRY_CAP="${CB_RETRY_CAP:-2}"; MAXP="${CB_MAX_PARALLEL:-2}"
LID="${CB_LAUNCHER_ID:-cb1}"
BOARD="$CB_HOME/board-gh.sh"
SPAWN="${CB_SPAWN:-$CB_HOME/crewboss-prep-spawn-gh.sh}"
mkdir -p "$STATE"
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
log(){ echo "[launcher-gh $(now)] $*"; }
sget(){ cat "$STATE/$1/$2" 2>/dev/null || echo ""; }
sset(){ mkdir -p "$STATE/$1"; printf '%s' "$3" > "$STATE/$1/$2"; }
board(){ bash "$BOARD" "$@"; }

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
  local id="$1" role
  role=$(board get "$id" role)
  board claim "$id" "$LID" >/dev/null
  sset "$id" pid "$$"; sset "$id" starttime "$(now)"
  log "claim #$id role=$role (pid $$)"
  "$SPAWN" "$id" "$role"; local ex=$?
  route "$id" "$ex"
}

# --- finale-merge-gate -------------------------------------------------------
# For each open charter/N -> main PR with green CI: promote to ready-for-review,
# post a comment, and idempotently create a type:human-decision board task so the
# cockpit operator has something actionable (F12 fix).
# Pattern mirrors the approval-gate block (type:human-decision + idempotency guard).
finale_merge_gate(){
  local pr_num pr_url charter_n existing inum ibody
  while IFS=$'\t' read -r pr_num pr_url charter_n; do
    [ -z "$pr_num" ] && continue
    # ── promote to ready-for-review + comment ──────────────────────────────
    gh pr ready "$pr_num" -R "$CB_REPO" 2>/dev/null || true
    gh pr comment "$pr_num" -R "$CB_REPO" \
      --body "CI is green. Finale PR is ready for merge." 2>/dev/null || true
    log "finale-merge-gate: charter #$charter_n PR $pr_url promoted to ready"
    # ── idempotency guard: skip if merge-gate human-decision issue exists ──
    existing=""
    while IFS= read -r inum; do
      [ -z "$inum" ] && continue
      ibody=$(gh issue view "$inum" -R "$CB_REPO" --json body -q '.body' 2>/dev/null || true)
      printf '%s\n' "$ibody" | grep -q "^merge-gate: true" && { existing="$inum"; break; }
    done < <(gh issue list -R "$CB_REPO" --state open --label "type:human-decision" \
        --search "Merge charter/$charter_n" --json number -q '.[].number' 2>/dev/null)
    if [ -n "$existing" ]; then
      log "finale-merge-gate: charter #$charter_n human-decision #$existing exists — skip"
      continue
    fi
    # ── create type:human-decision issue ─────────────────────────────────────
    gh issue create -R "$CB_REPO" \
      --title "Merge charter/$charter_n into main (PR: $pr_url)" \
      --label "type:human-decision" \
      --body "Charter: #$charter_n
PR-url: $pr_url
merge-gate: true

Finale PR is ready and CI is green. Use the Merge button in the cockpit to land this charter." 2>/dev/null || true
    log "finale-merge-gate: created human-decision issue for charter #$charter_n"
  done < <(gh pr list -R "$CB_REPO" --state open --base main \
    --json number,url,headRefName,statusCheckRollup \
    --jq '.[] | select(.headRefName | startswith("charter/")) |
          select(.statusCheckRollup | length > 0) |
          select(.statusCheckRollup | all(
            .status == "COMPLETED" and
            (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")
          )) |
          [.number | tostring, .url, (.headRefName | ltrimstr("charter/"))] | @tsv' \
    2>/dev/null)
}

cmd_once(){
  ( flock -n 9 || { log "another launcher holds the lock — exit"; exit 1; }
    reconcile
    # ── queue-mode detection ─────────────────────────────────────────────────
    local _q_order="" _q_head="" _q_disp="" _qn="" _qst="" _id_ch=""
    _q_order=$(jq -r '.order[]' "$RUN/queue.json" 2>/dev/null) || _q_order=""
    if [ -n "$_q_order" ]; then
      for _qn in $_q_order; do
        _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
        case "$_qst" in plan-review|done|blocked) continue ;; esac
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
    finale_merge_gate
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
    local poll="${CB_POLL:-2}" maxticks="${CB_MAX_TICKS:-120}" ticks=0 stop="" id pid ph prev tries running idle_ticks=0 _q_order="" _q_head="" _q_disp="" _qn="" _qst="" _id_ch=""
    reconcile   # STARTUP ONLY: requeue orphans from a previous run/reboot. Inside the loop,
                # the launcher started its own spawns, so a dead pid = finished (route by
                # status.json) — NOT an orphan; running reconcile per-tick would requeue every
                # normally-finished spawn before route-finished could route it.
    while :; do
      # kill-switch: stop the loop now (running spawns finish on their own / next reconcile).
      [ -f "$RUN/kill_switch" ] && { log "kill-switch present -> stop"; break; }
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
      running=$(running_count)
      # pause: keep managing in-flight spawns but claim NO new work until the flag is removed.
      if [ -f "$RUN/pause" ]; then
        log "paused — not claiming new (rm $RUN/pause to resume)"
      # claim new launchable up to the cap
      elif [ -z "$stop" ]; then
        # ── queue-mode detection (per tick) ──────────────────────────────────
        _q_order=$(jq -r '.order[]' "$RUN/queue.json" 2>/dev/null) || _q_order=""
        _q_head=""
        if [ -n "$_q_order" ]; then
          for _qn in $_q_order; do
            _qst=$(board get "$_qn" state 2>/dev/null || echo "unknown")
            case "$_qst" in plan-review|done|blocked) continue ;; esac
            _q_head="$_qn"; break
          done
          _q_disp=$(printf '%s' "$_q_order" | tr '\n' ',' | sed 's/,$//')
          log "queue-mode: order=[$_q_disp] head=#${_q_head:-none}"
        fi
        # plan charters first: a needs-plan charter -> spawn a tech-lead to decompose it
        # (it sets the charter to plan-review itself; local pid guard prevents double-spawn).
        for cid in $(board plannable); do
          [ "$running" -ge "$MAXP" ] && break
          # queue-mode: only head charter is eligible for planning
          if [ -n "$_q_order" ]; then
            [ -z "$_q_head" ] && break
            [ "$cid" = "$_q_head" ] || continue
          fi
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
          # queue-mode filter: only the head charter's leaves are eligible
          if [ -n "$_q_order" ]; then
            if [ -z "$_q_head" ]; then break; fi
            _id_ch=$(board get "$id" charter 2>/dev/null || echo "")
            [ "$_id_ch" = "$_q_head" ] || continue
          fi
          board claim "$id" "$LID" >/dev/null; sset "$id" starttime "$(now)"
          ( "$SPAWN" "$id" "$(board get "$id" role)" >/dev/null 2>&1 ) & sset "$id" pid "$!"
          running=$((running+1)); log "bg-spawn #$id (running=$running/$MAXP)"
        done
      fi
      # idle? nothing running AND (stopped OR no FRESH launchable). "fresh" excludes ids the
      # laggy gh list may still report but we've already handled (pid set / term).
      local fresh=0 fid
      for fid in $(board launchable) $(board plannable); do { [ -n "$(sget "$fid" pid)" ] || [ -n "$(sget "$fid" term)" ]; } || fresh=$((fresh+1)); done
      if [ "$running" -eq 0 ] && [ -n "$stop" ]; then log "stopped"; break; fi
      # idle-exit is DEBOUNCED: require CB_IDLE_CONFIRM consecutive empty ticks, so a transient
      # empty `board launchable` (gh read-after-write lag) doesn't end the run with work pending.
      if [ "$running" -eq 0 ] && [ "$fresh" -eq 0 ]; then
        idle_ticks=$((idle_ticks+1))
        [ "$idle_ticks" -ge "${CB_IDLE_CONFIRM:-2}" ] && { log "idle — run complete"; break; }
      else idle_ticks=0; fi
      finale_merge_gate
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
