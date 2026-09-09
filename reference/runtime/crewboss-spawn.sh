#!/usr/bin/env bash
# crewboss spawn primitive (design §4.4/§5/§9): run ONE agent in the fully-hardened
# jail (FS+net+seccomp) with the load-bearing rails baked in:
#   - budget pre-check (refuse to spawn if pool spend >= cost_pct cap)  [§5/§7]
#   - prompt-to-file (no title/body interpolation -> no injection)       [§4.4]
#   - redact_secrets on stdout/stderr -> run.log (0600)                  [§4.4]
#   - budget accounting: total_cost_usd -> run/budget.json under flock   [§5]
#   - status.json (0600): task/role/pid/starttime/phase/cost/pr/exit     [§9]
#
# Usage: crewboss-spawn.sh <task-id> <role> <prompt-file> <work-dir> [pr_repo]
# Env:   CLAUDE_CODE_OAUTH_TOKEN (req); GH_TOKEN/GH_REPO (if agent pushes)
# Exit:  0 ok · 2 agent failed · 3 budget hard-stop (did not spawn)
set -uo pipefail
umask 077
[ "$#" -ge 4 ] && [ "$#" -le 5 ] || { echo 'usage: crewboss-spawn.sh TASK ROLE PROMPT WORK [REPO]' >&2; exit 2; }
TASK="$1"; ROLE="$2"; PROMPTSRC="$3"; WORK="$4"; PR_REPO="${5:-}"
[[ "$TASK" =~ ^[0-9]+$ ]] && [ "${#TASK}" -le 20 ] && [[ "$ROLE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
  || { echo 'spawn: invalid task number or role identifier' >&2; exit 2; }
# provision: bind-mount modes from role capabilities (#356 AgentConfigMap P1 + #356 follow-up).
#   fs.work  → /work  (repo checkout); fs.cbnet → /cbnet (runtime: scripts, manifest, state).
#   ro → read-only bind (-R): the agent physically cannot write it, even via Bash (EROFS).
# FAIL-SAFE: empty/absent OR explicit "rw" → -B (read-write = today's behaviour, back-compat
#   for non-migrated roles); "ro" OR any other (typo'd) value → -R. A malformed capability
#   locks down, never silently opens (default-deny).
WORK_MOUNT="-R";  case "${CB_FS_WORK:-}"  in ""|rw) WORK_MOUNT="-B"  ;; esac
CBNET_MOUNT="-R"; case "${CB_FS_CBNET:-}" in ""|rw) CBNET_MOUNT="-B" ;; esac
[[ "${CB_MODEL:-}" == claude-* ]] && MODEL_FLAG="--model $CB_MODEL" || MODEL_FLAG=""
# dry-run hook: print the provisioning decision and exit before any jail/proxy/budget
# machinery, so the mount logic is unit-testable without nsjail (macOS/CI).
if [[ "${CB_SPAWN_DRYRUN:-}" == "1" ]]; then
  echo "WORK_MOUNT=$WORK_MOUNT CBNET_MOUNT=$CBNET_MOUNT role=$ROLE fs_work=${CB_FS_WORK:-} fs_cbnet=${CB_FS_CBNET:-} model_flag=${MODEL_FLAG}"
  exit 0
fi
# shellcheck source=run-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/run-env.sh" || exit 2
# Re-evaluate after loading operator configuration; malformed capabilities remain
# read-only just as they do for values passed directly by the role resolver.
WORK_MOUNT="-R";  case "${CB_FS_WORK:-}"  in ""|rw) WORK_MOUNT="-B"  ;; esac
CBNET_MOUNT="-R"; case "${CB_FS_CBNET:-}" in ""|rw) CBNET_MOUNT="-B" ;; esac
bash "$CB_HOME/crewboss-doctor.sh" --preflight || exit 2
[ -f "$PROMPTSRC" ] && [ -r "$PROMPTSRC" ] && [ -d "$WORK" ] && [ -w "$WORK" ] \
  || { echo 'spawn: readable prompt and writable work directory are required' >&2; exit 2; }
WORK="$(cd "$WORK" && pwd)"
RUN="$CB_HOME/run"
PROFILE="$CB_HOME/claude.kafel"
REDACT="$CB_HOME/redact.pl"
PROXY_PY="$CB_HOME/proxy.py"
mkdir -p "$RUN/work"
CFG="$RUN/config.json"; [ -f "$CFG" ] || echo '{"monthly_credit_usd":100,"cost_pct":80}' > "$CFG"
BUDGET="$RUN/budget.json"; [ -f "$BUDGET" ] || echo '{"spent_usd":0,"runs":[]}' > "$BUDGET"
TDIR="$RUN/work/$TASK"; mkdir -p "$TDIR"
LOG="$TDIR/run.log"; ST="$TDIR/status.json"
: > "$LOG"; chmod 600 "$LOG"

now(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
writestatus(){ # phase, exit, cost, pr
  jq -n --arg t "$TASK" --arg r "$ROLE" --arg ph "$1" --arg pid "${AGENT_PID:-}" \
        --arg st "${STARTTIME:-}" --arg ex "${2:-}" --arg c "${3:-0}" --arg pr "${4:-}" \
        --arg up "$(now)" \
    '{task:$t,role:$r,phase:$ph,pid:$pid,starttime:$st,exit_code:$ex,cost_usd:($c|tonumber),pr:$pr,updated_at:$up}' \
    > "$ST.tmp" && mv "$ST.tmp" "$ST"; chmod 600 "$ST"
}

# --- budget pre-check (refuse to spawn over cap) ---
CAP=$(jq -r '(.monthly_credit_usd * .cost_pct/100)' "$CFG")
SPENT=$(jq -r '.spent_usd' "$BUDGET")
OVER=$(awk -v s="$SPENT" -v c="$CAP" 'BEGIN{print (s>=c)?1:0}')
if [ "$OVER" = "1" ]; then
  AGENT_PID=""; STARTTIME=""
  writestatus "budget-stop" "" "$SPENT" ""
  echo "BUDGET HARD-STOP: spent \$$SPENT >= cap \$$CAP (cost_pct) — not spawning #$TASK" | tee -a "$LOG"
  exit 3
fi
echo "budget ok: spent \$$SPENT < cap \$$CAP" >> "$LOG"

# --- prompt to file (no interpolation) ---
[ "$PROMPTSRC" -ef "$TDIR/task.prompt" ] || cp "$PROMPTSRC" "$TDIR/task.prompt"

# --- proxy up (per-task socket: parallel-safe, no shared pkill) ---
SOCK="$TDIR/proxy.sock"; rm -f "$SOCK"
nohup python3 "$PROXY_PY" "$SOCK" > "$TDIR/proxy.out" 2>&1 &
PROXY_PID=$!
cleanup_spawn() {
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  rm -f "$SOCK" "$WORK/.task.prompt"
}
trap cleanup_spawn EXIT
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo 'spawn: proxy socket did not become ready' >&2; exit 2; }

STARTTIME=$(awk '{print $22}' /proc/self/stat)  # placeholder; real pid below
RO=()
for system_path in /usr /bin /lib /lib64 /sbin /etc; do
  [ ! -e "$system_path" ] || RO+=(-R "$system_path")
done
RO+=(-R "$CB_CLAUDE_INSTALL_DIR")
CLAUDE_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CB_CLAUDE_BIN")"
GH_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CB_GH_BIN")"
PE=(--env HTTPS_PROXY=http://127.0.0.1:3128 --env https_proxy=http://127.0.0.1:3128
    --env NO_PROXY=localhost,127.0.0.1 --env no_proxy=localhost,127.0.0.1)
# --- Session-token split (#1274 P4; canonicalized from the 2026-07-02 box hotpatch) ---
# Jail sessions authenticate as the machine account (own rate-limit bucket) when the
# operator provides CB_SESSION_GH_TOKEN (e.g. via ~/.crewboss.env); the launcher/API keep
# the owner token. With the variable unset behaviour is byte-identical to before.
if [ -n "${CB_SESSION_GH_TOKEN:-}" ]; then
  export GH_TOKEN="$CB_SESSION_GH_TOKEN"
  unset CB_SESSION_GH_TOKEN   # hygiene: do not leak the extra var into the jail (keep_env)
fi
GHENV=(--env GH_TOKEN)
[ -z "$PR_REPO" ] || GHENV+=(--env "GH_REPO=$PR_REPO")
AUTH_ENV=()
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || AUTH_ENV+=(--env CLAUDE_CODE_OAUTH_TOKEN)
[ -z "${ANTHROPIC_API_KEY:-}" ] || AUTH_ENV+=(--env ANTHROPIC_API_KEY)

# in-jail wrapper: bridge up, then claude reads the prompt from file
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'python3 /cbnet/bridge.py %q 3128 &\n' "/cbnet/run/work/$TASK/proxy.sock"
  printf 'BR=$!\ntrap '\''kill "$BR" 2>/dev/null || true'\'' EXIT\n'
  printf 'for i in $(seq 1 50); do (echo >/dev/tcp/127.0.0.1/3128) 2>/dev/null && break; sleep 0.1; done\n'
  printf '%q --agent %q ' "$CLAUDE_REAL" "$ROLE"
  [[ "${CB_MODEL:-}" != claude-* ]] || printf -- '--model %q ' "$CB_MODEL"
  printf '%s\n' '-p "$(cat /work/.task.prompt)" --output-format json'
} > "$TDIR/payload.sh"
cp "$TDIR/task.prompt" "$WORK/.task.prompt"

writestatus "starting" "" "0" ""
RESJSON="$TDIR/result.json"
set +e
# gh-shim wiring (charter #1274, leaf #1301):
#   --env CB_RL_STATE_FILE=/cbnet/run/rl_state — the in-jail path of the shared rate-limit
#     state file. Injected as an explicit --env AFTER -e so it OVERRIDES any HOST CB_RL_STATE_FILE
#     that keep_env (-e) would otherwise forward (same override-over-`-e` pattern as --env HOME);
#     the host path (e.g. $CB_HOME/run/rl_state) must NOT leak into the jail namespace.
#   -B "$CB_HOME/run:/cbnet/run" — a dedicated read-WRITE bind of run/ layered over the /cbnet
#     mount, so gh-shim.sh can atomically write rl_state even when the role runs CB_FS_CBNET=ro
#     (CBNET_MOUNT=-R makes /cbnet read-only, which would EROFS the state write without this).
#   --env CB_GH_REAL=/usr/bin/gh — explicit real-gh override (defense in depth against the
#     2026-07-03 fork-bomb: the `/cbnet/gh -> gh-shim.sh` PATH symlink self-selected as the
#     "real" gh and recursed. The resolver bug is fixed in gh-shim.sh; this override makes
#     the whole PATH-walk moot so the class cannot re-arm from a resolver regression).
# seccomp: the shim runs the real gh via execve, already in the claude.kafel allowlist.
"$CB_NSJAIL_BIN" -C "$CB_HOME/nsjail-limits.cfg" -Mo -t "${CB_TASK_TIMEOUT:-3600}" \
  --rlimit_cpu max --rlimit_nofile 8192 \
  --seccomp_policy "$PROFILE" --seccomp_log \
  "${RO[@]}" -R "$GH_REAL:/crewboss-gh-real" \
  -B "$CB_CLAUDE_CONFIG_DIR:$CB_AGENT_HOME/.claude" \
  -B "$CB_CLAUDE_CONFIG_FILE:$CB_AGENT_HOME/.claude.json" \
  -B /dev "$CBNET_MOUNT" "$CB_HOME:/cbnet" \
  -B "$CB_HOME/run:/cbnet/run" \
  "$WORK_MOUNT" "$WORK:/work" \
  -m none:/tmp:tmpfs:size=256M -e --env "HOME=$CB_AGENT_HOME" \
  --env CB_RL_STATE_FILE=/cbnet/run/rl_state --env CB_GH_REAL=/crewboss-gh-real --cwd /work \
  "${AUTH_ENV[@]}" "${GHENV[@]}" "${PE[@]}" \
  --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 --really_quiet \
  -- /bin/bash "/cbnet/run/work/$TASK/payload.sh" 2>&1 | perl "$REDACT" | tee -a "$LOG" > "$RESJSON.raw"
EX=${PIPESTATUS[0]}
set -e
cleanup_spawn
trap - EXIT

# the redacted run.log holds the JSON result line; extract last JSON object
# extractions must tolerate no-match (pipefail+set-e would otherwise kill the spawn
# on a smoke that opens no PR) -> `|| true`
COST=$( { grep -oE '"total_cost_usd":[0-9.]+' "$LOG" | tail -1 | cut -d: -f2; } || true ); COST=${COST:-0}
PR=$( { grep -oE 'https://github.com/[^ "]+/pull/[0-9]+' "$LOG" | tail -1; } || true )
IS_ERR=$( { grep -oE '"is_error":(true|false)' "$LOG" | tail -1 | cut -d: -f2; } || true )

# --- budget accounting under flock ---
( flock -x 9
  jq --arg t "$TASK" --arg r "$ROLE" --argjson c "${COST:-0}" --arg at "$(now)" \
     '.spent_usd = ((.spent_usd*1000 + ($c*1000))/1000) | .runs += [{task:$t,role:$r,cost:$c,at:$at}]' \
     "$BUDGET" > "$BUDGET.tmp" && mv "$BUDGET.tmp" "$BUDGET"
) 9>"$RUN/budget.lock"

if [ "$EX" = "0" ] && [ "$IS_ERR" = "false" ]; then PHASE="done"; RC=0; else PHASE="failed"; RC=2; fi
writestatus "$PHASE" "$EX" "${COST:-0}" "${PR:-}"
echo "spawn #$TASK role=$ROLE phase=$PHASE cost=\$${COST:-0} pr=${PR:-none} (total pool spent now \$$(jq -r .spent_usd "$BUDGET"))"
exit $RC
