#!/usr/bin/env bash
# crewboss-launcher.sh — Arch-2 launcher (REFERENCE). Polls the board and launches one
# executor per launchable leaf as a SEPARATE process (no in-session spawn). The launcher
# is NOT crewboss-gated itself — its safety is its OWN code (kill-switch, budget cap).
# Keep it small. Production would harden process-mgmt / claim-race / retry. See
# ../board-orchestration.md.
#
# Usage:
#   crewboss-launcher.sh [--once] [--dry-run] [--board-file F]
#     --once        run one cycle, then exit (default: loop)
#     --dry-run     compute + print planned launches; claim/launch/mutate NOTHING
#     --board-file  read board JSON from F instead of `gh issue list` (for tests)
#
# NB (live): a git worktree only contains TRACKED files, so the crewboss `.claude/`
# config must be committed (or copied into the worktree) for `--agent executor` to load
# + be gated there. The dry-run path needs none of this.

LAUNCHER_ID="${CREWBOSS_LAUNCHER_ID:-L1}"
CONCURRENCY="${CREWBOSS_CONCURRENCY:-3}"          # max executors per batch
BUDGET="${CREWBOSS_BUDGET:-50}"                   # hard cap on launches per run (anti-runaway)
RETRY_CAP="${CREWBOSS_RETRY_CAP:-1}"              # re-queue a failed leaf up to N times, then block
POLL_INTERVAL="${CREWBOSS_POLL_INTERVAL:-60}"     # idle sleep, seconds
KILL_SWITCH="${CREWBOSS_KILL_SWITCH:-.crewboss-launcher.stop}"
HEARTBEAT="${CREWBOSS_HEARTBEAT:-.crewboss-launcher.beat}"
WORKTREE_BASE="${CREWBOSS_WORKTREE_BASE:-../crewboss-worktrees}"

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHABLE="$HERE/launchable.sh"

ONCE=0; DRY=0; BOARD_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --once) ONCE=1 ;; --dry-run) DRY=1 ;; --board-file) BOARD_FILE="$2"; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done

launched_total=0
log(){ echo "[launcher $LAUNCHER_ID] $*"; }
if [ -t 1 ]; then _c(){ printf '\033[%sm%s\033[0m' "$1" "$2"; }; else _c(){ printf '%s' "$2"; }; fi
res(){ [ -n "${RESDIR:-}" ] && printf '%s' "$2" > "$RESDIR/$1" 2>/dev/null; return 0; }   # record per-task outcome for the cycle summary

fetch_board(){
  if [ -n "$BOARD_FILE" ]; then cat "$BOARD_FILE"
  else gh issue list --state all --limit 200 --json number,state,labels,body; fi
}

claim(){ # $1=issue — best-effort (single-process or partitioned use avoids contention)
  gh issue edit "$1" --add-label "status:in-progress" >/dev/null 2>&1
  gh issue comment "$1" --body "claimed by launcher \`$LAUNCHER_ID\`" >/dev/null 2>&1
}

handle_result(){ # $1=issue $2=exit_code
  local n="$1" rc="$2"
  if [ "$(gh pr list --head "task/$n" --json number --jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    gh issue edit "$n" --remove-label "status:in-progress" --add-label "status:review" >/dev/null 2>&1
    log "$(_c 32 ✓) #$n  PR opened → review"; res "$n" review
    return
  fi
  # failure: re-queue up to RETRY_CAP (prior failures counted from comments), else block.
  local fails; fails="$(gh issue view "$n" --json comments --jq '[.comments[].body | select(test("^executor failed \\(exit"))] | length' 2>/dev/null)"; fails="${fails:-0}"   # anchored sentinel — a human comment quoting the phrase must not consume retry budget
  if [ "$fails" -lt "$RETRY_CAP" ] 2>/dev/null; then
    gh issue edit "$n" --remove-label "status:in-progress" >/dev/null 2>&1   # back to launchable
    gh issue comment "$n" --body "executor failed (exit $rc), no PR — retry $((fails + 1))/$RETRY_CAP" >/dev/null 2>&1
    log "$(_c 33 ↻) #$n  no PR → retry $((fails + 1))/$RETRY_CAP"; res "$n" retry
  else
    gh issue edit "$n" --remove-label "status:in-progress" --add-label "status:blocked" >/dev/null 2>&1
    gh issue comment "$n" --body "executor failed (exit $rc), no PR — retry-cap ($RETRY_CAP) reached, needs tech-lead triage" >/dev/null 2>&1
    log "$(_c 31 ✗) #$n  retry-cap reached → blocked"; res "$n" blocked
  fi
}

launch_one(){ # $1=issue — background worker
  local n="$1" wt="$WORKTREE_BASE/task-$n"
  # NEVER force-reset (-B): a prior run / retry may have committed work + an open PR on task/$n,
  # and handle_result can mis-classify success on a transient `gh pr list` failure. -B would then
  # blow that committed work away. Create fresh; if the branch already exists, REUSE it as-is
  # (no reset) so commits/PR survive — a redundant re-run is wasteful, not destructive.
  if ! git worktree add -q -b "task/$n" "$wt" 2>/dev/null \
     && ! git worktree add -q "$wt" "task/$n" 2>/dev/null; then
    gh issue edit "$n" --remove-label "status:in-progress" >/dev/null 2>&1   # un-claim; infra/lost-race, NOT an executor failure
    log "$(_c 33 ⊘) #$n  worktree busy (branch checked-out / lost race) → un-claimed, no retry"; res "$n" skipped
    return
  fi
  ( cd "$wt" && claude --agent executor -p "Take issue #$n on this task/$n branch, open a PR with 'Closes #$n', then stop." )
  local rc=$?
  git worktree remove --force "$wt" 2>/dev/null
  handle_result "$n" "$rc"
}

cycle(){
  [ -f "$KILL_SWITCH" ] && { log "kill-switch present ($KILL_SWITCH) — stop"; return 1; }
  [ "$launched_total" -ge "$BUDGET" ] && { log "budget cap ($BUDGET) reached — stop"; return 1; }
  [ "$DRY" = "0" ] && date +%s > "$HEARTBEAT" 2>/dev/null

  local board launchable; board="$(fetch_board)"
  launchable="$(printf '%s' "$board" | bash "$LAUNCHABLE")"
  [ -z "$launchable" ] && { log "no launchable leaves — nothing to do"; return 2; }

  local count=0 pids=() RESDIR="" t0=0
  if [ "$DRY" = "0" ]; then
    RESDIR="$(mktemp -d)"; t0="$(date +%s)"
    log "launchable: $(echo $launchable) — up to $CONCURRENCY at a time"
  fi
  while read -r n; do
    [ -z "$n" ] && continue
    [ "$count" -ge "$CONCURRENCY" ] && break
    [ "$launched_total" -ge "$BUDGET" ] && break
    if [ "$DRY" = "1" ]; then log "DRY launch #$n"
    else log "$(_c 36 ▶) #$n  executor starting → task/$n"; claim "$n"; launch_one "$n" & pids+=($!); fi
    count=$((count + 1)); launched_total=$((launched_total + 1))
  done <<< "$launchable"

  if [ "$DRY" = "0" ] && [ "${#pids[@]}" -gt 0 ]; then
    wait "${pids[@]}"
    local f r=0 y=0 b=0 s=0
    for f in "$RESDIR"/*; do [ -e "$f" ] || continue
      case "$(cat "$f" 2>/dev/null)" in review) r=$((r+1)) ;; retry) y=$((y+1)) ;; blocked) b=$((b+1)) ;; skipped) s=$((s+1)) ;; esac
    done
    log "cycle done: $(_c 32 "$r review") · $y retry · $(_c 31 "$b blocked") · $s skipped · $(( $(date +%s) - t0 ))s"
  fi
  [ -n "$RESDIR" ] && rm -rf "$RESDIR"
  return 0
}

[ "$DRY" = "0" ] && git worktree prune 2>/dev/null   # clear stale worktrees from prior runs
[ "$DRY" = "0" ] && log "launcher $LAUNCHER_ID up — concurrency=$CONCURRENCY budget=$BUDGET retry-cap=$RETRY_CAP"
if [ "$ONCE" = "1" ]; then cycle; exit 0; fi
while true; do
  cycle; rc=$?
  [ "$rc" = "1" ] && break          # kill-switch / budget -> stop
  sleep "$POLL_INTERVAL"            # idle, or pause between batches
done
