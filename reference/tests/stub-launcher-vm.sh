#!/usr/bin/env bash
# stub-launcher-vm.sh — verify-merged finale gate (charter #685 test stub)
# Uses CB_INTEGRATOR verify-merged subcommand to gate auto-merge.
set -uo pipefail
: "${CB_REPO:?}"
CB_HOME="${CB_HOME:-/tmp/cbnet}"
INTEGRATOR_SCRIPT="${CB_INTEGRATOR:-}"
GIT_REMOTE="${CB_GIT_REMOTE:-}"
CB_POLL="${CB_POLL:-2}"
CB_IDLE_CONFIRM="${CB_IDLE_CONFIRM:-3}"
CB_MAX_TICKS="${CB_MAX_TICKS:-100}"

_run(){
    local idle=0 tick=0
    while true; do
        tick=$((tick+1)); [ "$tick" -gt "$CB_MAX_TICKS" ] && break
        _tick && idle=0 || idle=$((idle+1))
        [ "$idle" -ge "$CB_IDLE_CONFIRM" ] && break
        sleep "$CB_POLL"
    done
}

_tick(){
    local did=0 board cid
    board=$(gh issue list -R "$CB_REPO" --state all -L 200 2>/dev/null || echo "[]")
    while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        local ol
        ol=$(printf '%s' "$board" | jq -r --argjson c "$cid" '
          [.[]|select(.state=="OPEN")
              |select(([.labels[].name]|index("type:charter"))==null)
              |select((.body//"")|ascii_downcase|contains("charter: #"+($c|tostring)))]
          |length' 2>/dev/null) || ol=1
        [ "$ol" = "0" ] || continue
        local ep
        ep=$(gh pr list -R "$CB_REPO" --head "charter/$cid" --base main --state open \
             --json number 2>/dev/null | jq -r '.[0].number//empty' 2>/dev/null) || ep=""
        if [ -n "$ep" ]; then _vm_check "$cid" "$ep"; did=1; continue; fi
        local ha=() gl=() grc=0
        [ -n "${CB_HARNESS:-}" ]       && ha=(--harness "$CB_HARNESS")
        [ -n "${CB_GATE_REPO_DIR:-}" ] && gl=(--repo-dir "$CB_GATE_REPO_DIR")
        bash "$INTEGRATOR_SCRIPT" gate-charter "$cid" \
             "${ha[@]+"${ha[@]}"}" "${gl[@]+"${gl[@]}"}" 2>/dev/null || grc=$?
        [ "$grc" -eq 0 ] || { did=1; continue; }
        bash "$INTEGRATOR_SCRIPT" regen-persist "$cid" \
             --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>/dev/null || true
        gh pr create -R "$CB_REPO" --draft --base main --head "charter/$cid" \
           --title "Charter #$cid -> main" --body "Finale." 2>/dev/null || true
        local pn
        pn=$(gh pr list -R "$CB_REPO" --head "charter/$cid" --base main --state open \
             --json number 2>/dev/null | jq -r '.[0].number//empty' 2>/dev/null) || pn=""
        [ -n "$pn" ] || continue
        _vm_check "$cid" "$pn"; did=1
    done < <(printf '%s' "$board" | jq -r '
        .[]|select(.state=="OPEN")
           |select([.labels[].name]|index("type:charter")!=null)
           |.number' 2>/dev/null)
    [ "$did" -gt 0 ]
}

_vm_check(){
    local cid="$1" pr="$2" rc=0 out reason
    out=$(bash "$INTEGRATOR_SCRIPT" verify-merged "charter/$cid" "main" \
         --remote "$GIT_REMOTE" --repo "$CB_REPO" 2>/dev/null) || rc=$?
    reason=$(printf '%s\n' "$out" | sed -n 's/^RED_REASON: //p' | head -1)
    if [ "$rc" -eq 0 ]; then
        gh pr ready "$pr" -R "$CB_REPO" 2>/dev/null || true
        if [ "${CB_AUTO_MERGE:-0}" = "1" ]; then
            gh pr merge "$pr" -R "$CB_REPO" --admin --merge 2>/dev/null || true
            gh issue close "$cid" -R "$CB_REPO" --reason completed 2>/dev/null || true
        fi
    else
        gh issue comment "$cid" -R "$CB_REPO" \
           --body "charter-finale: verify-merged RED (${reason:-RED}) deferring" 2>/dev/null || true
    fi
}

case "${1:-}" in run) _run ;; *) echo "stub: unknown cmd $1" >&2; exit 1 ;; esac
