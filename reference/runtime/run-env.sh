#!/usr/bin/env bash
# run-env.sh — canonical env contract for the crewboss run loop.
# Source from ALL bash entrypoints: . "$(dirname "$0")/run-env.sh"
# Token lives in ~/.crewboss.env (mode 0600); credential-helper migration is a separate leaf.

# ── token source ──────────────────────────────────────────────────────────────
[ -f "$HOME/.crewboss.env" ] && . "$HOME/.crewboss.env"

# ── core vars ─────────────────────────────────────────────────────────────────
export CB_REPO="${CB_REPO:-stratch1989/crewboss}"
# CB_HOME set EXPLICITLY — closes the async with the launcher default /tmp/cbnet.
# UI kill/pause/status signals address $CB_HOME; differing values cause them to miss the loop.
export CB_HOME="$HOME/cbnet"
# T6 (tick budget): leaf ~8-10 min; launcher default CB_MAX_TICKS=120 = one batch only.
# Set >= 1800 here so entrypoints win over the launcher default.
export CB_MAX_TICKS="${CB_MAX_TICKS:-1800}"
export CB_MAX_PARALLEL="${CB_MAX_PARALLEL:-4}"
export CB_TASK_TIMEOUT="${CB_TASK_TIMEOUT:-3600}"
export CB_SPAWN="${CB_SPAWN:-$HOME/cbnet/charter-leaf-prep.sh}"

# ── GH token: env > ~/.crewboss.env > gh auth token ──────────────────────────
: "${GH_TOKEN:=$(gh auth token 2>/dev/null)}"
export GH_TOKEN

# ── integration URL (D2: ON by default; opt-out: CB_NO_INTEGRATE=1) ────────────
# Launcher contract F9a (#117): empty CB_GIT_REMOTE → integrator+finale DISABLED loud-once.
# The launcher-side contract is NOT changed here — only the entrypoint side sets this.
if [ "${CB_NO_INTEGRATE:-0}" = "1" ]; then
  export CB_GIT_REMOTE=""
else
  export CB_GIT_REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${CB_REPO}.git"
fi

export CB_PLAN_SPAWN="${CB_PLAN_SPAWN:-$HOME/cbnet/charter-plan-spawn.sh}"
export CB_HARNESS="${CB_HARNESS:-}"
# FIXME: CB_GATE_REPO_DIR default "." — gate-fix leaf replaces with absolute path (red→green there)
export CB_GATE_REPO_DIR="${CB_GATE_REPO_DIR:-.}"
