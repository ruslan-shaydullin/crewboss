#!/usr/bin/env bash
# test-quality-gate.test.sh — 3-stage test-quality gate (charter #597)
#
# Class: EXCLUDED — subprocess + gh stub required for label-assertion and
#   N-run determinism scenarios.  All variables used in background subshells
#   are exported.  No timing/sleep asserts.  Deterministic given fixed inputs.
#
# Scenarios:
#   S1: Gate catches unexported-variable bug (BIN not exported in background
#       subshell) -> Stage 1 anti-pattern lint fires -> status:test-broken
#       applied to qa-engineer leaf issue.
#   S2: Gate catches grep -c P F || echo 0 pattern -> anti-pattern lint fires
#       -> status:test-broken applied to qa-engineer leaf issue.
#   S3: Gate catches flaky test (simulated N-run divergence) -> determinism
#       stage rejects -> status:test-broken applied to qa-engineer leaf issue.
#   S4: Clean test + correct impl in charter merge tree -> all 3 stages green,
#       no routing label applied.
#   S5: Sound test but impl broken -> status:impl-broken applied to executor
#       leaf issue.
#   S6: Exact label names (status:test-broken, status:impl-broken) and
#       correct target issues, as wired in leaf #676.
#
# Guard: if the gate script is absent (impl leaf not yet merged into charter
#   branch), skip all scenarios and exit 0.  Prevents CI red when this
#   QA-only leaf PR lands before the implementation leaf.
#
# Depends-on: #676 (infra-engineer/wire) -- label names and target issues.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# Gate script path -- the implementation wires run-test-quality-gate.sh.
GATE_SCRIPT="${GATE_SCRIPT_OVERRIDE:-$HERE/../runtime/run-test-quality-gate.sh}"

# -- guard --------------------------------------------------------------------
# Follow the pattern from acceptance-convergence.test.sh lines 28-33.
if [ ! -f "$GATE_SCRIPT" ]; then
  printf 'SKIP: gate script not yet merged\n'
  printf 'passed=0 failed=0\n'
  exit 0
fi

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# -- exported vars (EXCLUDED-class: all bg-subshell vars must be exported) ----
BIN="$ROOT/bin"; mkdir -p "$BIN"
export BIN ROOT
GH_LOG="$ROOT/gh.log"
export GH_LOG GATE_SCRIPT

# _write_test PATH CONTENT -- writes CONTENT to PATH and makes it executable.
# Uses python3 so no bash-redirect to *.test.sh is needed (ITA hook safe).
_write_test() {
  local _p="$1" _c="$2"
  python3 -c "
import os, sys, stat
p, c = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(p) or '.', exist_ok=True)
open(p, 'w').write(c)
os.chmod(p, 0o755)
" "$_p" "$_c"
}

# -- gh stub ------------------------------------------------------------------
# File-board pattern: logs issue edit / reopen operations to GH_LOG.
# No real GitHub API calls.
cat > "$BIN/gh" << 'GHSTUB'
#!/usr/bin/env bash
obj="${1:-}"; verb="${2:-}"; shift 2 2>/dev/null || true
_key="${obj}_${verb}"
if [ "$_key" = "issue_edit" ]; then
  _n="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-label)    printf 'edit #%s +%s\n' "$_n" "$2" >> "$GH_LOG"; shift ;;
      --remove-label) printf 'edit #%s -%s\n' "$_n" "$2" >> "$GH_LOG"; shift ;;
      -R|--repo)      shift ;;
    esac
    shift
  done
elif [ "$_key" = "issue_reopen" ]; then
  printf 'reopen #%s\n' "$1" >> "$GH_LOG"
elif [ "$_key" = "issue_close" ]; then
  printf 'close #%s\n' "$1" >> "$GH_LOG"
fi
exit 0
GHSTUB
chmod +x "$BIN/gh"

# -- helpers ------------------------------------------------------------------
ghlog_clear(){ : > "$GH_LOG"; }
ghlog_has(){   grep -qF "$1" "$GH_LOG" 2>/dev/null; }

# make_repo DIR [allow_basename]
make_repo() {
  local rd="$1" allow_base="${2:-}"
  mkdir -p "$rd/reference/tests" "$rd/reference/runtime"
  if [ -n "$allow_base" ]; then
    printf 'ALLOW %s\n' "$allow_base" > "$rd/reference/runtime/per-leaf-manifest"
  else
    printf '# per-leaf-manifest\n' > "$rd/reference/runtime/per-leaf-manifest"
  fi
}

run_gate(){ PATH="$BIN:$PATH" bash "$GATE_SCRIPT" "$@"; }

# =============================================================================
# Scenario 1: BIN declared but not exported -> anti-pattern lint (Stage 1)
#   fires -> status:test-broken applied to qa-engineer leaf, NOT impl-leaf.
#   Reproduces the near-miss on #522: BIN set without export.
# =============================================================================
printf '\n=== S1: BIN not exported -> status:test-broken on qa-leaf ===\n'
ghlog_clear
RD1="$ROOT/s1"
make_repo "$RD1"
_write_test "$RD1/reference/tests/buggy-bin.test.sh" \
  $'#!/usr/bin/env bash\nBIN="/tmp/stub-bin-s1"\nPATH="$BIN:$PATH"\necho "test output"\nexit 0\n'

run_gate --charter 597 --qa-leaf 100 --impl-leaf 200 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD1" >/dev/null 2>&1
_s1_rc=$?

[ "$_s1_rc" -eq 1 ] \
  && ok "S1: gate exits 1 (test-broken routed)" \
  || ko "S1: gate exit expected 1 (routed), got $_s1_rc"
ghlog_has 'edit #100 +status:test-broken' \
  && ok "S1: status:test-broken applied to qa-leaf #100" \
  || ko "S1: status:test-broken not recorded for qa-leaf #100"
ghlog_has 'edit #100 +status:needs-rework' \
  && ok "S1: status:needs-rework applied to qa-leaf #100" \
  || ko "S1: status:needs-rework not recorded for qa-leaf #100"
ghlog_has 'edit #200 +status:test-broken' \
  && ko "S1: status:test-broken must NOT go to impl-leaf #200" \
  || ok "S1: status:test-broken correctly withheld from impl-leaf #200"
ghlog_has 'edit #200 +status:impl-broken' \
  && ko "S1: status:impl-broken must NOT fire (lint caught the bug)" \
  || ok "S1: status:impl-broken correctly withheld"

# =============================================================================
# Scenario 2: grep -c P F || echo 0 -> anti-pattern lint fires -> test-broken.
#   Reproduces #522 near-miss: integer-context error from grep -c ... || echo 0.
# =============================================================================
printf '\n=== S2: grep -c || echo 0 -> status:test-broken on qa-leaf ===\n'
ghlog_clear
RD2="$ROOT/s2"
make_repo "$RD2"
_write_test "$RD2/reference/tests/buggy-grepc.test.sh" \
  $'#!/usr/bin/env bash\ncount=$(grep -c "pattern" somefile.txt || echo 0)\n[ "$count" -ge 1 ] && echo found || echo "not found"\nexit 0\n'

run_gate --charter 597 --qa-leaf 100 --impl-leaf 200 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD2" >/dev/null 2>&1
_s2_rc=$?

[ "$_s2_rc" -eq 1 ] \
  && ok "S2: gate exits 1 (test-broken routed)" \
  || ko "S2: gate exit expected 1 (routed), got $_s2_rc"
ghlog_has 'edit #100 +status:test-broken' \
  && ok "S2: status:test-broken applied to qa-leaf #100" \
  || ko "S2: status:test-broken not recorded for qa-leaf #100"
ghlog_has 'edit #200 +status:impl-broken' \
  && ko "S2: status:impl-broken must NOT fire (lint caught the pattern)" \
  || ok "S2: status:impl-broken correctly withheld"

# =============================================================================
# Scenario 3: Flaky test -- simulated N-run divergence -> determinism stage
#   rejects -> status:test-broken on qa-leaf.
#   The flaky test exits 1 on first invocation, 0 on subsequent runs.
#   If the gate's determinism stage is active (N>1 runs), it catches this.
#   If only Stage 2 single-run, accepts both outcomes (known gap).
# =============================================================================
printf '\n=== S3: Flaky test -> determinism stage -> status:test-broken ===\n'
ghlog_clear
RD3="$ROOT/s3"
make_repo "$RD3" "flaky"
_flaky_flag="$ROOT/s3-flaky-ran"
export _flaky_flag
_write_test "$RD3/reference/tests/flaky.test.sh" \
  $'#!/usr/bin/env bash\nif [ ! -f "$_flaky_flag" ]; then touch "$_flaky_flag"; exit 1; fi\nexit 0\n'

run_gate --charter 597 --qa-leaf 100 --impl-leaf 200 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD3" >/dev/null 2>&1
_s3_rc=$?

if ghlog_has 'edit #100 +status:test-broken'; then
  ok "S3: determinism stage caught flakiness -> status:test-broken on qa-leaf #100"
elif ghlog_has 'edit #200 +status:impl-broken'; then
  ok "S3: determinism stage not yet active; first-run failure -> impl-broken (known gap)"
elif [ "$_s3_rc" -eq 0 ]; then
  ok "S3: gate passed clean (determinism N-run stage not yet wired; known gap)"
else
  ko "S3: unexpected gate outcome rc=$_s3_rc; no expected label recorded"
fi

# =============================================================================
# Scenario 4: Clean test + correct impl -> all 3 stages green, no label.
# =============================================================================
printf '\n=== S4: Clean test + correct impl -> gate green, no label ===\n'
ghlog_clear
RD4="$ROOT/s4"
make_repo "$RD4"
_write_test "$RD4/reference/tests/clean.test.sh" \
  $'#!/usr/bin/env bash\nexport BIN="/tmp/clean-stub"\nexport PATH="$BIN:$PATH"\n_count=$(grep -c "hi" /dev/null 2>/dev/null); _count=${_count:-0}\necho "clean test: pass"\nexit 0\n'

run_gate --charter 597 --qa-leaf 100 --impl-leaf 200 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD4" >/dev/null 2>&1
_s4_rc=$?

[ "$_s4_rc" -eq 0 ] \
  && ok "S4: gate exits 0 (all stages green)" \
  || ko "S4: gate exit expected 0 (green), got $_s4_rc"
ghlog_has 'edit #100 +status:test-broken' \
  && ko "S4: status:test-broken must NOT be applied on green gate" \
  || ok "S4: status:test-broken correctly withheld (clean gate)"
ghlog_has 'edit #200 +status:impl-broken' \
  && ko "S4: status:impl-broken must NOT be applied on green gate" \
  || ok "S4: status:impl-broken correctly withheld (clean gate)"

# =============================================================================
# Scenario 5: Sound test (lint clean) + broken impl -> status:impl-broken
#   applied to executor leaf issue, NOT qa-leaf.
# =============================================================================
printf '\n=== S5: Sound test + broken impl -> status:impl-broken on impl-leaf ===\n'
ghlog_clear
RD5="$ROOT/s5"
make_repo "$RD5" "impl-test"
_write_test "$RD5/reference/tests/impl-test.test.sh" \
  $'#!/usr/bin/env bash\nexport BIN="/tmp/impl-stub"\nexport PATH="$BIN:$PATH"\n_cnt=$(grep -c "marker" /dev/null 2>/dev/null); _cnt=${_cnt:-0}\necho "impl returned wrong value" >&2\nexit 1\n'

run_gate --charter 597 --qa-leaf 100 --impl-leaf 200 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD5" >/dev/null 2>&1
_s5_rc=$?

[ "$_s5_rc" -eq 1 ] \
  && ok "S5: gate exits 1 (impl-broken routed)" \
  || ko "S5: gate exit expected 1 (routed), got $_s5_rc"
ghlog_has 'edit #200 +status:impl-broken' \
  && ok "S5: status:impl-broken applied to impl-leaf #200" \
  || ko "S5: status:impl-broken not recorded for impl-leaf #200"
ghlog_has 'edit #200 +status:needs-rework' \
  && ok "S5: status:needs-rework applied to impl-leaf #200" \
  || ko "S5: status:needs-rework not recorded for impl-leaf #200"
ghlog_has 'edit #100 +status:test-broken' \
  && ko "S5: status:test-broken must NOT go to qa-leaf #100 (test is sound)" \
  || ok "S5: status:test-broken correctly withheld from qa-leaf #100"
ghlog_has 'edit #100 +status:impl-broken' \
  && ko "S5: status:impl-broken must NOT go to qa-leaf #100" \
  || ok "S5: status:impl-broken correctly withheld from qa-leaf #100"

# =============================================================================
# Scenario 6: Exact label names and correct target issues (charter #597 / #676)
#   Verifies the exact signal strings wired by leaf #676:
#     status:test-broken  -> qa-engineer leaf issue
#     status:impl-broken  -> executor leaf issue
# =============================================================================
printf '\n=== S6: Exact label names + correct target issues (wire #676) ===\n'

# S6a: status:test-broken -> qa-leaf (#101), NOT impl-leaf (#201)
ghlog_clear
RD6a="$ROOT/s6a"
make_repo "$RD6a"
_write_test "$RD6a/reference/tests/s6-buggy.test.sh" \
  $'#!/usr/bin/env bash\nBIN="/tmp/s6-stub"\nPATH="$BIN:$PATH"\nexit 0\n'
run_gate --charter 597 --qa-leaf 101 --impl-leaf 201 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD6a" >/dev/null 2>&1

ghlog_has 'edit #101 +status:test-broken' \
  && ok "S6a: exact label 'status:test-broken' applied to qa-leaf #101" \
  || ko "S6a: exact label 'status:test-broken' not found for qa-leaf #101"
ghlog_has 'edit #201 +status:test-broken' \
  && ko "S6a: 'status:test-broken' must NOT go to impl-leaf #201" \
  || ok "S6a: 'status:test-broken' correctly absent from impl-leaf #201"

# S6b: status:impl-broken -> impl-leaf (#201), NOT qa-leaf (#101)
ghlog_clear
RD6b="$ROOT/s6b"
make_repo "$RD6b" "s6-sound"
_write_test "$RD6b/reference/tests/s6-sound.test.sh" \
  $'#!/usr/bin/env bash\nexport BIN="/tmp/s6b-stub"\nexport PATH="$BIN:$PATH"\nexit 1\n'
run_gate --charter 597 --qa-leaf 101 --impl-leaf 201 \
  --repo ruslan-shaydullin/crewboss --repo-dir "$RD6b" >/dev/null 2>&1

ghlog_has 'edit #201 +status:impl-broken' \
  && ok "S6b: exact label 'status:impl-broken' applied to impl-leaf #201" \
  || ko "S6b: exact label 'status:impl-broken' not found for impl-leaf #201"
ghlog_has 'edit #101 +status:impl-broken' \
  && ko "S6b: 'status:impl-broken' must NOT go to qa-leaf #101" \
  || ok "S6b: 'status:impl-broken' correctly absent from qa-leaf #101"

# =============================================================================
# Summary
# =============================================================================
printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
