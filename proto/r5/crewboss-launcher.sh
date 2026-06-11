#!/usr/bin/env bash
# crewboss launcher loop (design §4.6/§9, board-orchestration). Deterministic backend:
# reads a board, computes launchable, claims, spawns ONE agent per task, routes the result.
# Board = run/board/*.json (local stand-in for the GitHub issue+label board).
# SPAWN is overridable ($CB_SPAWN) so the loop is testable with a stub (no spend).
#
# Subcommands:  reconcile | once
# Env: CB_HOME (default /tmp/cbnet), CB_SPAWN (default crewboss-spawn.sh wrapper),
#      CB_RETRY_CAP (default 2), CB_MAX_PARALLEL (default 2)
set -uo pipefail
CB_HOME="${CB_HOME:-/tmp/cbnet}"
RUN="$CB_HOME/run"; BOARD="$RUN/board"
LOCK="$RUN/launcher.lock"
RETRY_CAP="${CB_RETRY_CAP:-2}"
SPAWN="${CB_SPAWN:-$CB_HOME/crewboss-spawn.sh}"
mkdir -p "$BOARD"
now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
jget(){ jq -r "$2" "$BOARD/$1.json" 2>/dev/null; }
jset(){ # id, jq-expr
  jq "$2" "$BOARD/$1.json" > "$BOARD/$1.json.tmp" && mv "$BOARD/$1.json.tmp" "$BOARD/$1.json"; }
log(){ echo "[launcher $(now)] $*"; }

charter_state(){ local c="$1"; [ -z "$c" ] || [ "$c" = "null" ] && { echo approved; return; }
  jget "$c" '.state'; }

dep_done(){ # returns 0 if all deps are done/closed
  local id="$1" deps d st
  deps=$(jget "$id" '.deps[]?' 2>/dev/null)
  for d in $deps; do
    st=$(jget "$d" '.state')
    [ "$st" = "done" ] || [ "$st" = "closed" ] || return 1
  done
  return 0
}

launchable(){ # id -> 0 if launchable
  local id="$1"
  [ "$(jget "$id" '.kind')" = "leaf" ] || return 1
  [ "$(jget "$id" '.state')" = "open" ] || return 1
  [ "$(jget "$id" '.held')" = "true" ] && return 1
  [ "$(charter_state "$(jget "$id" '.charter')")" = "approved" ] || return 1
  dep_done "$id" || return 1
  return 0
}

reconcile(){ # requeue in-progress tasks whose pid is dead (reboot / SIGKILL orphans)
  local f id pid
  for f in "$BOARD"/*.json; do [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    [ "$(jget "$id" '.state')" = "in-progress" ] || continue
    pid=$(jget "$id" '.pid')
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "reconcile: #$id still alive (pid $pid)"
    else
      log "reconcile: #$id orphaned (pid '$pid' dead) -> requeue"
      jset "$id" '.state="open" | .pid="" | .starttime=""'
    fi
  done
}

route(){ # id, spawn-exit
  local id="$1" ex="$2" tries
  case "$ex" in
    0) jset "$id" '.state="done" | .pid="" | .ended_at="'"$(now)"'"'; log "#$id -> done" ;;
    3) jset "$id" '.state="open" | .pid="" | .starttime=""'; log "#$id budget hard-stop -> requeued, STOPPING cycle"; return 9 ;;
    *) tries=$(( $(jget "$id" '.tries') + 1 ))
       if [ "$tries" -ge "$RETRY_CAP" ]; then
         jset "$id" '.state="blocked" | .pid="" | .tries='"$tries"; log "#$id failed (try $tries) -> blocked (cap $RETRY_CAP)"
       else
         jset "$id" '.state="open" | .pid="" | .tries='"$tries"; log "#$id failed (try $tries) -> requeued"
       fi ;;
  esac
  return 0
}

claim_and_spawn(){ # id
  local id="$1" role
  role=$(jget "$id" '.role')
  jset "$id" '.state="in-progress" | .pid="'"$$"'" | .starttime="'"$(now)"'"'
  log "claim #$id role=$role (pid $$)"
  # NB: stub contract is `$SPAWN <id> <role>`. The REAL crewboss-spawn.sh needs
  # `<id> <role> <prompt-file> <work-dir> [pr_repo]` — so a prod adapter must, per task,
  # render the prompt from the issue body and do the §4.5 repo prep (mirror->local clone
  # ->push-fix->branch) BEFORE calling spawn, then pass the full args. That glue is the
  # next integration step; this loop validates the state machine with the 2-arg stub.
  "$SPAWN" "$id" "$role"; local ex=$?
  route "$id" "$ex"
}

cmd_once(){
  ( flock -n 9 || { log "another launcher holds the lock — exit"; exit 1; }
    reconcile
    local f id launched=0
    for f in "$BOARD"/*.json; do [ -e "$f" ] || continue
      id=$(basename "$f" .json)
      launchable "$id" || continue
      [ "$launched" -ge "${CB_MAX_PARALLEL:-2}" ] && { log "parallel cap reached"; break; }
      claim_and_spawn "$id"; local rc=$?
      launched=$((launched+1))
      [ "$rc" = "9" ] && break   # budget stop ends the cycle
    done
    log "cycle done: launched=$launched"
  ) 9>"$LOCK"
}

case "${1:-once}" in
  reconcile) ( flock -n 9 || { log "locked"; exit 1; }; reconcile ) 9>"$LOCK" ;;
  once) cmd_once ;;
  *) echo "usage: $0 {once|reconcile}"; exit 64 ;;
esac
