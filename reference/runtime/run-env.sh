#!/usr/bin/env bash
# run-env.sh — единый источник env-контракта Run-петли (issue #147)
# Сорсят: run-charter.sh, start-stack.sh
#
# D1 (почва): токен живёт в ~/.crewboss.env (0600).
# D2: интеграция ВКЛ по умолчанию; отключается явным CB_NO_INTEGRATE=1.

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
if [ "${CB_NO_INTEGRATE:-}" = "1" ]; then
  export CB_GIT_REMOTE=""
else
  export CB_GIT_REMOTE="${CB_GIT_REMOTE:-https://x-access-token:${GH_TOKEN}@github.com/${CB_REPO}.git}"
fi

export CB_PLAN_SPAWN="${CB_PLAN_SPAWN:-$HOME/cbnet/crewboss-prep-spawn-gh.sh}"
export CB_HARNESS="${CB_HARNESS:-}"
# FIXME: CB_GATE_REPO_DIR default '.' is a known issue (gate-fix leaf will set correct path)
export CB_GATE_REPO_DIR="${CB_GATE_REPO_DIR:-.}"
