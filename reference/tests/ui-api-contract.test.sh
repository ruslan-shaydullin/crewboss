#!/usr/bin/env bash
# ui-api-contract.test.sh — static UI↔API contract check (issue #68, class b-static)
#
# Extracts action-literals from ALL of ui/app/src:
#   (a) FIRST-ARG strings of command('...')/onAction('...')/run('...') calls in .ts/.tsx
#       — captures majority: approve/kill/unkill/run/comment/hold/unhold/request-changes/
#         resolve-decision/pause/resume (the last two via ternary special-case)
#   (b) action:'...' payload literals in api.ts dedicated wrapper functions
#       (delete-comment/resolve-decision/set-check)
#
# Extraction uses precise patterns:
#   Direct:  (command|onAction|run)\(['"]action-name['"] — matches first-arg string literals
#   Ternary: run(expr ? 'action1' : 'action2') — matches ?/'action' and :/'action' patterns
#   Payload: action: 'action-name' in api.ts
#
# Verifies FULL set against do_command branches in ui/server/crewboss-api.py.
#
# Sanity-minimum: approve/kill/run/comment/hold must be found.
# Red-fixture: copy of App.tsx with unknown action via command() → test must catch it.
#
# RED now: (a) scanning only api.ts misses majority of App.tsx actions (approve/kill/run/etc.)
# GREEN after: full extraction, all known actions verified against do_command.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
UISRC="$REPO_ROOT/ui/app/src"
API_PY="$REPO_ROOT/ui/server/crewboss-api.py"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── helpers ───────────────────────────────────────────────────────────────────
extract_ui_actions(){
  local src_dir="$1"
  # (a) Direct first-argument string: command('action'), onAction('action'), run('action')
  #     Pattern: (command|onAction|run)( immediately followed by a quoted lowercase string.
  #     This avoids false positives from lines like command(variable) or toast(r.ok?'ok':'failed').
  local direct
  direct=$(find "$src_dir" \( -name '*.ts' -o -name '*.tsx' \) -print0 2>/dev/null | \
    xargs -0 grep -hoP "(command|onAction|run)\(['\"]([a-z][a-z-]+)['\"]" 2>/dev/null | \
    grep -oP "['\"][a-z][a-z-]+['\"]" | tr -d "'\"" | sort -u)

  # (b) Ternary first-arg: run(expr ? 'action1' : 'action2')
  #     Look for single-quoted lowercase strings immediately after '? ' or ': ' on lines
  #     that contain run( — covers the pause/resume ternary in App.tsx.
  local ternary
  ternary=$(find "$src_dir" \( -name '*.ts' -o -name '*.tsx' \) -print0 2>/dev/null | \
    xargs -0 grep -h "run(" 2>/dev/null | \
    grep -oP "(?<=[?:] )'[a-z][a-z-]+'" | tr -d "'" | sort -u)

  # (c) api.ts payload literals: action: 'action-name' in dedicated wrapper functions
  local payloads
  payloads=$(find "$src_dir" \( -name '*.ts' -o -name '*.tsx' \) -print0 2>/dev/null | \
    xargs -0 grep -hoP "action:[[:space:]]*['\"]([a-z][a-z-]+)['\"]" 2>/dev/null | \
    grep -oP "['\"][a-z][a-z-]+['\"]" | tr -d "'\"" | sort -u)

  printf '%s\n%s\n%s\n' "$direct" "$ternary" "$payloads" | sort -u | grep -v '^$'
}

extract_api_actions(){
  local api_py="$1"
  {
    # (a) Literal branches: a=="action-name" in do_command
    grep -oP 'a=="([a-z][a-z-]+)"' "$api_py" 2>/dev/null | \
      grep -oP '"[a-z][a-z-]+"' | tr -d '"'
    # (b) Constant-based branches: `a == CMD_X` / `a in (CMD_X, CMD_Y)` where the
    #     constant is defined at module level as CMD_X = "action-name". The old
    #     literal-only pattern was blind to these (chronic baseline RED: approve-hd/
    #     close-hd/request-changes-hd — incident 2026-07-03, factology theme G5).
    local c
    for c in $(grep -P '\ba\s*(==|in\s*\()' "$api_py" 2>/dev/null | \
                 grep -oP 'CMD_[A-Z_]+' | sort -u); do
      grep -oP "^\s*${c}\s*=\s*\"\K[a-z][a-z-]+(?=\")" "$api_py" 2>/dev/null
    done
  } | sort -u | grep -v '^$'
}

# ── 1. Check ui/app/src and crewboss-api.py exist ─────────────────────────────
if [ ! -d "$UISRC" ]; then
  no "ui/app/src directory not found: $UISRC"
  echo; printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi
if [ ! -f "$API_PY" ]; then
  no "crewboss-api.py not found: $API_PY"
  echo; printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"; exit 1
fi

# ── 2. Extract UI actions ─────────────────────────────────────────────────────
echo "=== Extract UI action literals from ui/app/src ==="
ui_actions=$(extract_ui_actions "$UISRC")
echo "  extracted UI actions: $(echo "$ui_actions" | tr '\n' ' ')"

# ── 3. Sanity-minimum: extractor must find core actions ───────────────────────
echo "=== Sanity-minimum: extractor must find approve/kill/run/comment/hold ==="
extractor_ok=1
for must in approve kill run comment hold; do
  if echo "$ui_actions" | grep -qx "$must"; then
    ok "sanity: '$must' found in extracted UI actions"
  else
    no "sanity FAIL: '$must' NOT found — extractor is blind (check extraction logic)"
    extractor_ok=0
  fi
done

# ── 4. Extract API actions from do_command ────────────────────────────────────
echo "=== Extract API do_command branches from crewboss-api.py ==="
api_actions=$(extract_api_actions "$API_PY")
echo "  API do_command actions: $(echo "$api_actions" | tr '\n' ' ')"

# ── 5. Contract check: every UI action must exist in do_command ───────────────
echo "=== Contract check: all UI actions exist in API do_command ==="
if [ "$extractor_ok" -eq 1 ]; then
  contract_fail=0
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    if echo "$api_actions" | grep -qx "$action"; then
      ok "UI action '$action' → API do_command: matched"
    else
      no "UI action '$action' → API do_command: MISSING (would return 'unknown action')"
      contract_fail=$((contract_fail+1))
    fi
  done <<< "$ui_actions"
  if [ "$contract_fail" -eq 0 ]; then
    echo "  contract: all UI actions have API handlers ✓"
  fi
else
  echo "  SKIP contract check — extractor sanity failed first"
fi

# ── 6. Red-fixture demonstration ──────────────────────────────────────────────
echo "=== Red-fixture: unknown action via command() is caught statically ==="
APP_TSX="$UISRC/App.tsx"
FIXTURE_APP="$TMP/App.tsx.fixture"

if [ ! -f "$APP_TSX" ]; then
  no "App.tsx not found — cannot run red-fixture demonstration"
else
  # Inject unknown action via generic command() call (simulates developer adding action without API pair)
  cp "$APP_TSX" "$FIXTURE_APP"
  echo "const _redFixture = () => command('unknown-action-fixture-xyz', 42)" >> "$FIXTURE_APP"

  # Use fixture dir (copy of src with modified App.tsx) for extraction
  FIXTURE_SRC="$TMP/fixture-src"
  cp -r "$UISRC" "$FIXTURE_SRC"
  cp "$FIXTURE_APP" "$FIXTURE_SRC/App.tsx"

  fixture_ui=$(extract_ui_actions "$FIXTURE_SRC")

  # The extractor must find the injected unknown action
  if echo "$fixture_ui" | grep -q "unknown-action-fixture-xyz"; then
    ok "red-fixture: extractor found injected unknown action 'unknown-action-fixture-xyz'"
  else
    no "red-fixture: extractor MISSED injected unknown action — extractor is blind"
  fi

  # The contract check must catch it as missing from api.py
  fixture_missed=0
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    if ! echo "$api_actions" | grep -qx "$action"; then
      fixture_missed=$((fixture_missed+1))
    fi
  done <<< "$fixture_ui"

  if [ "$fixture_missed" -gt 0 ]; then
    ok "red-fixture: contract check flags $fixture_missed unknown action(s) pre-deploy ✓"
  else
    no "red-fixture: contract check did NOT flag unknown action — static detection broken"
  fi
fi

echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
