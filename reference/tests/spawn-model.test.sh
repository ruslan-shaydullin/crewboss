#!/usr/bin/env bash
# spawn-model.test.sh — CB_MODEL two-tier policy unit tests (charter #1234 P2).
# Drives reference/runtime/crewboss-spawn.sh via CB_SPAWN_DRYRUN=1 seam (expanded by P2 to
# emit model_flag=${MODEL_FLAG}). Pure unit test: no nsjail, no spend, no network.
#
# T1: CB_MODEL=claude-opus-4-8 (matches claude-*) → model_flag=--model claude-opus-4-8
# T2: CB_MODEL=anthropic       (does not match claude-*) → no --model flag in output
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$HERE/../runtime/crewboss-spawn.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# Temp manifest dir following agentconfig-fswork.test.sh pattern
mkdir -p "$ROOT/manifest/roles"

run_spawn() {   # <model-value>
  local model="$1"
  printf -- '---\nname: test-role\nkind: executor\ntools: Read, Bash\nprofile: executor\nmodel: %s\n---\nbody\n' \
    "$model" > "$ROOT/manifest/roles/test-role.md"
  CB_HOME="$ROOT/h" CB_SPAWN_DRYRUN=1 CB_MODEL="$model" \
    bash "$SPAWN" 5 test-role /dev/null "$ROOT/w" 2>&1
}

# ── T1: claude-opus-4-8 → --model flag ───────────────────────────────────────────────────
echo "=== T1: CB_MODEL=claude-opus-4-8 → model_flag=--model claude-opus-4-8 ==="
out=$(run_spawn "claude-opus-4-8")
if printf '%s' "$out" | grep -q 'model_flag=--model claude-opus-4-8'; then
  ok "T1: CB_MODEL=claude-opus-4-8 → model_flag=--model claude-opus-4-8"
else
  ko "T1: expected 'model_flag=--model claude-opus-4-8' in output; got: $out"
fi

# ── T2: anthropic → no --model flag ─────────────────────────────────────────────────────
echo "=== T2: CB_MODEL=anthropic → no --model flag ==="
out=$(run_spawn "anthropic")
if printf '%s' "$out" | grep -q -- '--model'; then
  ko "T2: CB_MODEL=anthropic must NOT emit --model flag; got: $out"
else
  ok "T2: CB_MODEL=anthropic → no --model flag (non-claude model, flag suppressed)"
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
