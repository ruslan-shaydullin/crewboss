#!/usr/bin/env bash
# Board I/O and delivery transitions shared by the launcher and focused tests.
# 0 = confirmed business result, 75 = infrastructure/read/write failure.
# Infrastructure failures persist across command substitutions via one run file.
_cb_infra_pending(){ [ -f "$RUN/infra-failure" ]; }
_cb_infra_failed(){
  mkdir -p "$RUN"
  printf '%s\n' "$*" > "$RUN/infra-failure"
  printf 'board infrastructure failure: %s; retry without a business transition\n' "$*" >&2
  return 75
}
_cb_clear_infra(){ rm -f "$RUN/infra-failure"; }
_cb_retry_tick(){
  ticks=$((ticks+1))
  [ "$ticks" -lt "$maxticks" ] || return 75
  sleep "${CB_INFRA_BACKOFF:-$poll}"
}
_cb_spawn(){
  _cb_infra_pending && return 75
  "$@"
}
_cb_state_get(){ cat "$STATE/$1/$2" 2>/dev/null || :; }
_cb_state_set(){
  _cb_infra_pending && return 75
  if [ "$2" = term ] && [ "$3" = 1 ]; then
    local confirmed
    confirmed=$(_cb_board get "$1" state) || return 75
    case "$confirmed" in done|review|blocked|hold|deferred|approved|plan-review) ;;
      *) printf 'refusing terminal run-state for #%s: board still %s\n' "$1" "$confirmed" >&2; return 75 ;;
    esac
  fi
  mkdir -p "$STATE/$1"
  [ "$2" != starttime ] || rm -f "$STATE/$1/counted_completion"
  printf '%s' "$3" > "$STATE/$1/$2"
}
# Keep transport failure status even when an older caller suppresses diagnostics.
# A failed read must also prevent subsequent direct writes in that tick.
gh(){
  case "${1:-} ${2:-}" in
    'issue edit'|'issue close'|'issue create'|'issue reopen'|'issue comment'|'pr merge'|'pr create')
      _cb_infra_pending && return 75 ;;
  esac
  local fields="" previous="" query="" arg output rc=0
  for arg in "$@"; do
    [ "$previous" != --json ] || fields="$arg"
    case "$arg" in -q|--jq|--jq=*) query=1 ;; esac
    previous="$arg"
  done
  if [ -n "$fields" ] && [ -z "$query" ]; then
    output=$(command gh "$@") || rc=$?
  else
    command gh "$@" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    # label create is idempotent and gh uses the same error code for already-exists.
    [ "${1:-} ${2:-}" = 'label create' ] || _cb_infra_failed "gh ${1:-} ${2:-} (exit $rc)"
    return "$rc"
  fi
  if [ -n "$fields" ] && [ -z "$query" ]; then
    if ! printf '%s' "$output" | jq -e --arg fields "$fields" --arg operation "${2:-}" '
      def validrow:
        type=="object" and (. as $row | all($fields|split(",")[]; . as $key | $row|has($key)))
        and (if has("labels") then (.labels|type)=="array" and all(.labels[]; (.name|type)=="string") else true end)
        and (if has("comments") then (.comments|type)=="array" and all(.comments[]; (.body|type)=="string") else true end);
      if $operation=="list" then type=="array" and all(.[]; validrow) else validrow end
    ' >/dev/null; then
      _cb_infra_failed "invalid JSON from gh ${1:-} ${2:-}"; return 75
    fi
    printf '%s\n' "$output"
  fi
}
_cb_board(){
  case "${1:-}" in route|claim) _cb_infra_pending && return 75 ;; esac
  local output
  output=$(bash "$BOARD" "$@") || { _cb_infra_failed "board ${1:-} ${2:-}"; return 75; }
  if [ "${1:-}" = get ]; then
    case "${3:-}:$output" in
      state:done|state:review|state:blocked|state:hold|state:deferred|state:approved|state:plan-review|state:needs-plan|state:team-review|state:needs-analysis|state:needs-triage|state:needs-recovery|state:needs-rework|state:in-progress|state:open|state:needs-conflict-resolution) ;;
      state:*) _cb_infra_failed "invalid board state for #$2"; return 75 ;;
      role:) _cb_infra_failed "missing role for #$2"; return 75 ;;
    esac
  fi
  [ -z "$output" ] || printf '%s\n' "$output"
}

_cb_labels(){
  local payload
  payload=$(gh issue view "$1" -R "$CB_REPO" --json labels) || return 75
  if ! printf '%s' "$payload" | jq -e 'type == "object" and (.labels | type == "array") and all(.labels[]; .name | type == "string")' >/dev/null; then
    _cb_infra_failed "invalid labels for #$1"; return 75
  fi
  printf '%s' "$payload" | jq -c '[.labels[].name]'
}
_cb_has_label(){
  local labels
  labels=$(_cb_labels "$1") || return 75
  printf '%s' "$labels" | jq -r --arg label "$2" 'index($label) != null'
}
_cb_snapshot(){
  local payload
  if declare -F _cb_issue_list >/dev/null; then
    payload=$(_cb_issue_list all) || return 75
  else
    payload=$(gh issue list -R "$CB_REPO" --state all --limit 100000 --json number,state,labels,body,title) || return 75
  fi
  printf '%s' "$payload" | jq -e 'type == "array" and all(.[]; type == "object" and (.number|type)=="number" and (.state|type)=="string" and (.labels|type)=="array" and all(.labels[]; (.name|type)=="string"))' >/dev/null \
    || { _cb_infra_failed "invalid board snapshot"; return 75; }
  printf '%s' "$payload"
}
# Count a finished process once even when routing its result requires several
# ticks. A new spawn resets counted_completion when its starttime is persisted.
_cb_completion_attempt(){
  local id="$1" count
  _cb_infra_pending && return 75
  count=$(_cb_state_get "$id" tries); count=${count:-0}
  if [ ! -f "$STATE/$id/counted_completion" ]; then
    count=$((count+1))
    _cb_state_set "$id" tries "$count" || return 75
    : > "$STATE/$id/counted_completion"
  fi
  printf '%s' "$count"
}
_cb_finish_leaf(){
  local id="$1" outcome="$2" reason="${3:-}"
  _cb_infra_pending && return 75
  # Persist a delivery intent, not a terminal result. Retry this same transition
  # after a failed write instead of counting the completed session a second time.
  mkdir -p "$STATE/$id"
  printf '%s' "$outcome" > "$STATE/$id/pending_route"
  printf '%s' "$reason" > "$STATE/$id/pending_reason"
  _cb_board route "$id" "$outcome" "$reason" >/dev/null || return 75
  _cb_state_set "$id" term 1 || return 75
  _cb_state_set "$id" pid ""
  rm -f "$STATE/$id/pending_route" "$STATE/$id/pending_reason"
}
_cb_reconcile_state(){
  local d id state pending phase pid kind
  for d in "$STATE"/*/; do
    [ -d "$d" ] || continue
    id=${d%/}; id=${id##*/}
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    pending=$(_cb_state_get "$id" pending_route)
    if [ -n "$pending" ]; then
      _cb_finish_leaf "$id" "$pending" "$(_cb_state_get "$id" pending_reason)" || return 75
      continue
    fi
    [ "$(_cb_state_get "$id" term)" = 1 ] || continue
    state=$(_cb_board get "$id" state) || return 75
    kind=$(_cb_board get "$id" kind) || return 75
    if [ "$kind" = charter ]; then
      case "$state" in done|plan-review|approved|blocked|hold|deferred) continue ;; esac
      _cb_state_set "$id" term "" || return 75
      printf 'reconcile: charter #%s runtime state disagrees with %s; resuming its charter lifecycle\n' "$id" "$state" >&2
      continue
    fi
    case "$state" in done|review|blocked|hold|deferred|approved) continue ;; esac
    _cb_state_set "$id" term "" || return 75
    phase=$(jq -r '.phase // ""' "$RUN/work/$id/status.json" 2>/dev/null) || phase=""
    if [ "$phase" = done ]; then
      printf 'reconcile: #%s completed work still in %s; retrying review delivery\n' "$id" "$state" >&2
      _cb_finish_leaf "$id" review || return 75
    else
      printf 'reconcile: #%s terminal run-state disagrees with board %s; reopening runtime state\n' "$id" "$state" >&2
      _cb_state_set "$id" term ""
      # Never kill a process or erase an actual semantic attempt during repair.
      pid=$(_cb_state_get "$id" pid)
      [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null || _cb_state_set "$id" pid ""
    fi
  done
}
_cb_reviewer_role(){
  case "$1" in reviewer|final-review|final-reviewer|*-reviewer) return 0 ;; *) return 1 ;; esac
}
_cb_reviewer_consume(){
  local id="$1" role payload verdict rc action target own charter target_charter target_kind target_state
  role=$(_cb_board get "$id" role) || return 75
  _cb_reviewer_role "$role" || return 1  # PR-deliverable leaf.
  payload=$(gh issue view "$id" -R "$CB_REPO" --json comments) || return 75
  printf '%s' "$payload" | jq -e 'type=="object" and (.comments|type)=="array" and all(.comments[]; (.body|type)=="string")' >/dev/null \
    || { _cb_infra_failed "invalid reviewer comments for #$id"; return 75; }
  rc=0
  verdict=$(printf '%s' "$payload" | python3 "$HERE_LAUNCHER/reviewer-verdict.py") || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -eq 3 ] || printf 'reviewer #%s: invalid structured delivery; awaiting correction\n' "$id" >&2
    return 2  # A reviewer never falls through to the no-PR stale watchdog.
  fi
  action=$(printf '%s' "$verdict" | jq -r .verdict)
  if [ "$action" = blocked ]; then
    target=$(printf '%s' "$verdict" | jq -r .target)
    charter=$(_cb_board get "$id" charter) || return 75
    target_charter=$(_cb_board get "$target" charter) || return 75
    own=$(_cb_board get "$target" role) || return 75
    target_kind=$(_cb_board get "$target" kind) || return 75
    if [ "$target" = "$id" ] || [ -z "$charter" ] || [ "$target_charter" != "$charter" ] || [ "$target_kind" != leaf ]; then
      printf 'reviewer #%s: target #%s is not another leaf of the same charter\n' "$id" "$target" >&2
      return 2
    fi
    # Final review normally follows a completed/merged leaf. A rework label on a
    # closed issue cannot make it runnable; confirm reopening before delivery.
    target_state=$(_cb_board get "$target" state) || return 75
    if [ "$target_state" = done ]; then
      gh issue reopen "$target" -R "$CB_REPO" >/dev/null || return 75
    fi
    _cb_board route "$target" needs-rework "Reviewer #$id blocked delivery; assigned back to $own. $(printf '%s' "$verdict" | jq -r .reason)" >/dev/null || return 75
    _cb_state_set "$target" term ""
    _cb_state_set "$target" int_done ""
    _cb_state_set "$target" pid ""
  fi
  gh issue close "$id" -R "$CB_REPO" >/dev/null || return 75
  _cb_state_set "$id" int_done "reviewer-$action"
  _cb_state_set "$id" term 1 || return 75
  _cb_state_set "$id" pid ""
  rm -f "$STATE/$id/stale_ticks"
}
_cb_queue_park(){
  local snapshot order cid labels blocked active ticks cap temp runnable predicate charter_pid
  [ -f "$RUN/queue.json" ] || return 0
  order=$(jq -er '.order | if type=="array" then .[] else error("order must be an array") end' "$RUN/queue.json") || {
    # Empty queue is a valid state; malformed JSON is not.
    jq -e '.order == []' "$RUN/queue.json" >/dev/null 2>&1 && return 0
    _cb_infra_failed "invalid queue.json"; return 75
  }
  snapshot=$(_cb_snapshot) || return 75
  predicate="${CB_LAUNCHABLE:-$HERE_LAUNCHER/launchable.sh}"
  [ -f "$predicate" ] || predicate="$HERE_LAUNCHER/../launcher/launchable.sh"
  runnable=$(printf '%s' "$snapshot" | bash "$predicate") || return 75
  runnable=$(printf '%s\n' "$runnable" | jq -Rsc 'split("\n") | map(select(length>0)|tonumber)') || return 75
  cap=${CB_QUEUE_BLOCKED_TICKS:-10}
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || { _cb_infra_failed "invalid CB_QUEUE_BLOCKED_TICKS"; return 75; }
  for cid in $order; do
    labels=$(printf '%s' "$snapshot" | jq -ce --argjson cid "$cid" 'first(.[] | select(.number==$cid)) | if . == null then error("missing queued charter") else {state, labels:[.labels[].name]} end') || return 75
    printf '%s' "$labels" | jq -e '(.state|ascii_upcase)=="CLOSED" or any(.labels[]; .=="hold" or .=="status:hold" or .=="status:blocked" or .=="status:deferred")' >/dev/null && continue
    charter_pid=$(_cb_state_get "$cid" pid)
    if { [ -n "$charter_pid" ] && kill -0 "$charter_pid" 2>/dev/null; } \
       || ! printf '%s' "$labels" | jq -e '
          any(.labels[]; .=="status:approved" or .=="status:in-progress")
          and all(.labels[]; .!="status:needs-plan" and .!="status:needs-analysis"
            and .!="status:plan-review" and .!="status:team-review"
            and .!="status:acceptance-review" and .!="status:review"
            and .!="status:needs-conflict-resolution")' >/dev/null; then
      # Blocked execution leaves from an earlier attempt cannot park a charter
      # while its own manager is running or it is at an upstream/manual gate.
      _cb_state_set "$cid" queue_blocked_ticks 0 || return 75
      return 0
    fi
    blocked=$(printf '%s' "$snapshot" | jq -r --argjson cid "$cid" '
      .[] | select((.state|ascii_upcase)=="OPEN")
      | select((.body//"") | test("(?mi)^[\\s*_>#-]*Charter\\s*:\\s*#?" + ($cid|tostring) + "(?:\\s|$)"))
      | select(any(.labels[].name; .=="status:blocked")) | .number') || return 75
    active=$(printf '%s' "$snapshot" | jq -r --argjson cid "$cid" --argjson runnable "$runnable" '
      .[] | select((.state|ascii_upcase)=="OPEN")
      | select((.body//"") | test("(?mi)^[\\s*_>#-]*Charter\\s*:\\s*#?" + ($cid|tostring) + "(?:\\s|$)"))
      | select(any(.labels[].name; .=="type:agent"))
      | select(all(.labels[].name; .!="status:blocked" and .!="hold" and .!="status:hold" and .!="status:deferred"))
      | select(.number as $n | ($runnable|index($n)) != null or any(.labels[].name; .=="status:in-progress" or .=="status:review")) | .number') || return 75
    if [ -z "$blocked" ] || [ -n "$active" ]; then
      _cb_state_set "$cid" queue_blocked_ticks 0
      return 0  # First active head has usable work; leave its position intact.
    fi
    ticks=$(_cb_state_get "$cid" queue_blocked_ticks); ticks=$((${ticks:-0}+1))
    _cb_state_set "$cid" queue_blocked_ticks "$ticks"
    [ "$ticks" -ge "$cap" ] || return 0
    # Label and explanatory comment must both be confirmed before removing order.
    gh issue comment "$cid" -R "$CB_REPO" --body "Queue parked after $ticks ticks: blocked leaves $(printf '%s' "$blocked" | sed 's/^/#/' | tr '\n' ' '). Resume after resolving the blockers and removing hold." >/dev/null || return 75
    gh issue edit "$cid" -R "$CB_REPO" --add-label hold >/dev/null || return 75
    temp=$(mktemp "$RUN/queue.XXXXXX") || return 75
    jq --argjson cid "$cid" '.order |= map(select(. != $cid))' "$RUN/queue.json" > "$temp" \
      && mv "$temp" "$RUN/queue.json" || { rm -f "$temp"; return 75; }
    printf 'queue: parked charter #%s; continuing unrelated queued work\n' "$cid" >&2
    # Continue to the next head in the same tick.
  done
}
