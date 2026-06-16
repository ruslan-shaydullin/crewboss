#!/usr/bin/env bash
# manifest-connect.test.sh — CB_MANIFEST integration in crewboss-launcher-gh.sh (issue #132).
#
# Class: unit/integration-stub.  Stubs only `gh` (PATH shim); launcher and manifest
# library are REAL.  Expectations are on exit-code and log content (state-based, no sleep).
#
# RED-a: CB_MANIFEST=<broken manifest, no roles/> → launcher exits 65 BEFORE any board
#        call (gh-stub log stays empty).
# RED-b: CB_MANIFEST=<valid copy of team-example> → launcher starts, "manifest: ... ok"
#        appears in log, exits 0.
# GREEN-guard: no CB_MANIFEST → "manifest" substring absent from launcher log
#              (legacy behaviour byte-for-byte unchanged).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="${LAUNCHER_OVERRIDE:-$HERE/../runtime/crewboss-launcher-gh.sh}"
MANIFEST_LIB="$HERE/../launcher/manifest.sh"
TEAM_EXAMPLE="$(cd "$HERE/../../team-example" && pwd)"
BOARD_GH_SRC="$HERE/../../proto/r6/board-gh.sh"
LAUNCHABLE_SRC="$HERE/../../proto/r6/launchable.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

GH_LOG="$ROOT/gh.log"
BOARD_STATE="$ROOT/board.json"
export GH_LOG BOARD_STATE

# ── minimal gh stub ───────────────────────────────────────────────────────────
# Logs every call to GH_LOG; returns empty board so loop idle-exits immediately.
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
obj="$1"; verb="${2:-}"
case "$obj $verb" in
  "issue list") printf '[]\n' ;;
  "pr list")    printf '[]\n' ;;
  *) ;;
esac
exit 0
GHEOF
chmod +x "$BIN/gh"

# ── CB_HOME setup helper ──────────────────────────────────────────────────────
setup_cbhome(){
  local cbhome="$1"
  rm -rf "$cbhome"; mkdir -p "$cbhome"
  cp "$BOARD_GH_SRC"   "$cbhome/board-gh.sh"
  cp "$LAUNCHABLE_SRC" "$cbhome/launchable.sh"
  chmod +x "$cbhome/board-gh.sh" "$cbhome/launchable.sh"
}

# ── noop spawn stub ───────────────────────────────────────────────────────────
NOOP_SPAWN="$ROOT/noop-spawn.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_SPAWN"
chmod +x "$NOOP_SPAWN"

# =============================================================================
echo "== RED-a: broken manifest (no roles/) → exit 65, no board call =="
# =============================================================================

CBHOME_A="$ROOT/cbhome_a"
setup_cbhome "$CBHOME_A"
: > "$GH_LOG"

# Broken manifest: copy of team-example with roles/ removed.
# manifest-doctor.sh is present but will fail (all node role files missing).
BROKEN="$ROOT/broken_manifest"
cp -r "$TEAM_EXAMPLE/." "$BROKEN"
rm -rf "$BROKEN/roles"

exit_a=0
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_A" \
  CB_MANIFEST="$BROKEN" \
  CB_MANIFEST_LIB="$MANIFEST_LIB" \
  CB_SPAWN="$NOOP_SPAWN" \
  CB_POLL=0 \
  CB_MAX_TICKS=5 \
  CB_IDLE_CONFIRM=1 \
  bash "$LAUNCHER" run 2>/dev/null || exit_a=$?

[ "$exit_a" = "65" ] \
  && ok "RED-a: exit 65 on invalid manifest (fail-fast)" \
  || ko "RED-a: expected exit 65, got $exit_a"

# gh must NOT have been called — fail-fast precedes any board interaction
gh_lines_a="$(wc -l < "$GH_LOG" 2>/dev/null | tr -d ' ')"
[ "${gh_lines_a:-0}" = "0" ] \
  && ok "RED-a: gh stub not called before fail-fast (board untouched)" \
  || ko "RED-a: gh was called ${gh_lines_a} time(s) before fail-fast (expected 0)"

# =============================================================================
echo "== RED-b: valid manifest → 'manifest: ... ok' in launcher log =="
# =============================================================================

CBHOME_B="$ROOT/cbhome_b"
setup_cbhome "$CBHOME_B"
: > "$GH_LOG"
printf '[]\n' > "$BOARD_STATE"

# Valid manifest: clean copy of team-example
VALID="$ROOT/valid_manifest"
cp -r "$TEAM_EXAMPLE/." "$VALID"

LOGFILE_B="$ROOT/launcher_b.log"
exit_b=0
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_B" \
  CB_MANIFEST="$VALID" \
  CB_MANIFEST_LIB="$MANIFEST_LIB" \
  CB_SPAWN="$NOOP_SPAWN" \
  CB_POLL=0 \
  CB_MAX_TICKS=5 \
  CB_IDLE_CONFIRM=1 \
  bash "$LAUNCHER" run >"$LOGFILE_B" 2>&1 || exit_b=$?

[ "$exit_b" = "0" ] \
  && ok "RED-b: launcher exited 0 (valid manifest accepted)" \
  || ko "RED-b: launcher exited $exit_b (expected 0)"

grep -q "manifest:.*ok" "$LOGFILE_B" \
  && ok "RED-b: log contains 'manifest: ... ok'" \
  || ko "RED-b: log does NOT contain 'manifest: ... ok' (log: $(grep -i manifest "$LOGFILE_B" || echo none))"

# =============================================================================
echo "== GREEN-guard: no CB_MANIFEST → no 'manifest' substring in launcher log =="
# =============================================================================

CBHOME_G="$ROOT/cbhome_g"
setup_cbhome "$CBHOME_G"
: > "$GH_LOG"
printf '[]\n' > "$BOARD_STATE"

LOGFILE_G="$ROOT/launcher_g.log"
PATH="$BIN:$PATH" \
  CB_REPO="test/repo" \
  CB_HOME="$CBHOME_G" \
  CB_SPAWN="$NOOP_SPAWN" \
  CB_POLL=0 \
  CB_MAX_TICKS=5 \
  CB_IDLE_CONFIRM=1 \
  bash "$LAUNCHER" run >"$LOGFILE_G" 2>&1 || true

! grep -qi "manifest" "$LOGFILE_G" \
  && ok "GREEN-guard: 'manifest' absent from log without CB_MANIFEST (legacy unchanged)" \
  || ko "GREEN-guard: 'manifest' found in log without CB_MANIFEST — legacy behaviour broken"

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
