#!/usr/bin/env bash
# marker-gate.test.sh — class-a deterministic tests for the marker-grep gate (issue #70).
#
# The charter->main gate greps for leftover debug/bypass markers across ALL committed
# files including *.css.  The old box logic EXCLUDED *.css, so a marker committed to a
# stylesheet silently passed the gate (bug).  This test:
#
#  RED demonstration  (old logic, *.css excluded):
#    fixture/ has a .css file with the marker CREWBOSS_NOGATE;
#    old grep logic (excludes *.css) produces 0 hits -> gate passes -> BUG.
#
#  GREEN (new logic, *.css included):
#    same fixture; new grep logic finds the .css file -> gate blocks -> CORRECT.
#
# Both assertions must hold for the test to exit 0 (green in CI).
# If crewboss-integrator.sh is ABSENT from reference/runtime/, the test fails
# immediately (gate absent = red).
#
# Requires: bash, find, grep.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="$HERE/../runtime/crewboss-integrator.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── gate-script presence check ───────────────────────────────────────────────
echo "== gate-script presence =="
if [ ! -f "$INTEGRATOR" ]; then
  ko "crewboss-integrator.sh ABSENT from reference/runtime/ — gate missing"
  echo; echo "passed=$pass failed=$fail"; exit 1
fi
ok "crewboss-integrator.sh present in reference/runtime/"

# ── build a test fixture directory ───────────────────────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE"

MARKER="CREWBOSS_NOGATE"

# Write marker into .css, .sh, and clean .js files
printf '/* %s — do not commit */\n.foo { color: red; }\n' "$MARKER" > "$FIXTURE/style.css"
printf '# clean shell file\necho hello\n'                            > "$FIXTURE/clean.sh"
printf '// clean js file\nconsole.log("ok");\n'                     > "$FIXTURE/app.js"

# ── helper: old grep logic (excludes *.css) ──────────────────────────────────
# Mimics the box (proto/r8) behaviour that caused the bug.
old_marker_grep() {
  local dir="${1:-.}"
  find "$dir" -type f \
    \( -name "*.sh"   -o -name "*.bash" \
    -o -name "*.js"   -o -name "*.mjs"  -o -name "*.cjs" \
    -o -name "*.ts"   -o -name "*.tsx" \
    -o -name "*.json" -o -name "*.html" \
    -o -name "*.md" \
    \) \
    ! -path "*/.git/*" ! -path "*/node_modules/*" \
    | xargs grep -l "$MARKER" 2>/dev/null || true
}

# ── helper: new grep logic (includes *.css) — sourced from integrator ────────
# We source just the function; the integrator uses the same pattern internally.
new_marker_grep() {
  local dir="${1:-.}"
  find "$dir" -type f \
    \( -name "*.sh"   -o -name "*.bash" \
    -o -name "*.js"   -o -name "*.mjs"  -o -name "*.cjs" \
    -o -name "*.ts"   -o -name "*.tsx" \
    -o -name "*.css"  -o -name "*.scss" \
    -o -name "*.json" -o -name "*.html" \
    -o -name "*.md"   -o -name "*.txt" \
    \) \
    ! -path "*/.git/*" ! -path "*/node_modules/*" \
    | xargs grep -l "$MARKER" 2>/dev/null || true
}

# ── RED: old logic misses the marker in .css ─────────────────────────────────
echo "== old logic (*.css excluded) — should MISS marker in style.css =="
old_hits="$(old_marker_grep "$FIXTURE")"
if [ -z "$old_hits" ]; then
  ok "RED confirmed: old grep produced 0 hits (marker in .css was invisible)"
else
  ko "RED not confirmed: old grep found files: $old_hits (test fixture may be wrong)"
fi

# ── GREEN: new logic catches the marker in .css ───────────────────────────────
echo "== new logic (*.css included) — should FIND marker in style.css =="
new_hits="$(new_marker_grep "$FIXTURE")"
if printf '%s' "$new_hits" | grep -q "style.css"; then
  ok "GREEN: new grep found style.css containing marker"
else
  ko "GREEN NOT reached: new grep missed style.css — marker: $MARKER"
fi

# ── integrator gate-charter uses the new (inclusive) logic ───────────────────
echo "== integrator gate-charter blocks on fixture dir containing .css marker =="
# The fixture dir has style.css with CREWBOSS_NOGATE; no harness needed.
if CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --repo-dir "$FIXTURE" >/dev/null 2>&1; then
  ko "integrator gate-charter returned 0 on fixture with .css marker (should block)"
else
  ok "integrator gate-charter blocked on .css marker (exit non-zero)"
fi

# ── integrator gate-charter passes on a clean directory ──────────────────────
echo "== integrator gate-charter passes on clean directory =="
CLEAN_DIR="$TMP/clean"; mkdir -p "$CLEAN_DIR"
printf '/* no markers here */\n.bar { color: blue; }\n' > "$CLEAN_DIR/clean.css"
if CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --repo-dir "$CLEAN_DIR" >/dev/null 2>&1; then
  ok "integrator gate-charter passed on clean directory"
else
  ko "integrator gate-charter failed on clean directory (false positive)"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
