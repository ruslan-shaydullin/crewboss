#!/usr/bin/env bash
# run-env.sh — единый источник env-контракта Run-петли (issue #147)
# Сорсят: run-charter.sh, start-stack.sh
#
# D1 (почва): токен живёт в ~/.crewboss.env (0600).
# D2: интеграция ВКЛ по умолчанию; отключается явным CB_NO_INTEGRATE=1.
# D1/token: GH_TOKEN НЕ вшивается в URL — используется git credential-helper (inline).

# Load operator secrets / overrides from ~/.crewboss.env if present
# shellcheck source=/dev/null
[ -f "$HOME/.crewboss.env" ] && . "$HOME/.crewboss.env"

# ── Core ──────────────────────────────────────────────────────────────────────
export CB_REPO="${CB_REPO:-stratch1989/crewboss}"
# CB_HOME явный $HOME/cbnet (закрывает рассинхрон с дефолтом лаунчера /tmp/cbnet)
export CB_HOME="$HOME/cbnet"
# CB_MAX_TICKS не меньше 1800 (T6 тик-бюджет: лист ~8-10 мин, 120 тиков = один батч)
export CB_MAX_TICKS="${CB_MAX_TICKS:-1800}"
export CB_MAX_PARALLEL="${CB_MAX_PARALLEL:-4}"
export CB_TASK_TIMEOUT="${CB_TASK_TIMEOUT:-3600}"
export CB_SPAWN="${CB_SPAWN:-$HOME/cbnet/charter-leaf-prep.sh}"

# ── Gate / integrator env (F8 contract — soft link, just pass through) ────────
GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null)}"
export GH_TOKEN

# D2: интеграция ВКЛ по умолчанию; CB_NO_INTEGRATE=1 → пусто → лаунчер громко дизейблит
# integrator+finale И rework/escalation trigger (off-mode != off-escalation, #207)
# Token-free URL: GH_TOKEN lives only in env; credential-helper provides it at git call time.
if [ "${CB_NO_INTEGRATE:-}" = "1" ]; then
  export CB_GIT_REMOTE=""
else
  export CB_GIT_REMOTE="${CB_GIT_REMOTE:-https://github.com/${CB_REPO}.git}"
fi

# ── Inline git credential helper (issue #149 — token hygiene) ────────────────
# Registered via GIT_CONFIG_* (highest git precedence; overrides .gitconfig).
# Inline function — no file path — valid in both host and jail namespaces.
# nsjail keep_env (-e, crewboss-spawn.sh:82) + --env GH_TOKEN (spawn.sh:62) carry
# both this registration and the token into the jail on every spawn.
# shellcheck disable=SC2016
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f'

export CB_PLAN_SPAWN="${CB_PLAN_SPAWN:-$HOME/cbnet/crewboss-prep-spawn-gh.sh}"
# CB_HARNESS: passthrough — empty by default; gate uses marker-grep only; override for harness tests.
export CB_HARNESS="${CB_HARNESS:-}"
# Gate location for charter finale: intentionally NOT configured here.
# Production uses --remote (launcher:549-552) so the gate clones the real charter/C
# branch tree and avoids false-RED from CWD self-matches (F8 contract, #116).
# The --repo-dir override remains available for reference/tests (gate-charter-tree etc.).

# ── Leaf green-before-merge verifier env (charter #173 Ф-A, #177) ─────────────
# Leaf GREEN-BEFORE-MERGE is box-native: verify-merged runs engine suite on the
# merged tree from try-merge — NOT GHA statusCheckRollup, NO leaf-freshness gate
# (freshness guard F4 removed; FRESHNESS_THRESHOLD NOT exported on leaf path).
# Production default: enabled (HD-1).
#
# CB_VERIFY_CACHE  — verdict cache dir (#175); mirrors integrator priority logic:
#                    CB_VERIFY_CACHE → $CB_HOME/run/verify-cache → mktemp per-run.
# CB_VERIFY_TIMEOUT — engine-run ceiling in seconds (#174 F2 timeout wrap); default 600.
export CB_VERIFY_CACHE="${CB_VERIFY_CACHE:-$CB_HOME/run/verify-cache}"
export CB_VERIFY_TIMEOUT="${CB_VERIFY_TIMEOUT:-600}"
# CB_VERIFY_CONFIRM_N — consecutive real-red confirmations before terminal fail-cache
#                     + escalation trigger (#195/#196: one counter, one threshold); default 2.
export CB_VERIFY_CONFIRM_N="${CB_VERIFY_CONFIRM_N:-2}"
# CB_REWORK_CAP — max reworks before a confirmed-red leaf is routed to blocked (#196 L3).
export CB_REWORK_CAP="${CB_REWORK_CAP:-2}"
