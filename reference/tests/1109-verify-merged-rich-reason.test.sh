#!/usr/bin/env bash
# 1109-verify-merged-rich-reason.test.sh — charter #1048 / issue #1109 (qa-engineer leaf).
#
# RED→GREEN contract for ENRICHING the verify-merged RED reason so it carries the
# EXACT failing assertion (not just the failing-test basename).
#
# Against the CURRENT reference/runtime/crewboss-integrator.sh behaviour these tests
# are RED: cmd_verify_merged runs each engine test as `bash "$t" >/dev/null 2>&1`
# (output discarded) and appends ONLY `$_base` (basename) to the reason file, later
# joined `sort -u | paste -sd, -` and printed as `RED_REASON: <...>` plus written to
# `${_cache_file}.reason`. The assertion text never surfaces.
#
# The implementation leaf (which merges AFTER this qa leaf) makes them GREEN by
# capturing each failing test's output, truncating it to a BOUNDED single line, and
# embedding the assertion fragment into the per-test reason while PRESERVING the
# basename (backwards-compat) and the single-line / comma-join / cache /
# N-confirmation contract.
#
# T1: assertion present + basename preserved (RED now: assertion fragment absent)
# T2: bounded output — assertion present but truncated, no megabyte dump (RED now)
# T3: single-line invariant — launcher `sed -n 's/^RED_REASON: //p' | head -1`
#     still yields a non-empty, assertion-bearing line (RED now: no assertion)
# T4: verdict/cache/N-confirmation regression — pass caches+clears, red bumps+confirms
#     at CB_VERIFY_CONFIRM_N, multi-test comma-joins, infra exits 2 (GREEN now+after)
#
# This file drives cmd_verify_merged against bare-remote fixtures (recursive
# verify-merged) -> EXCLUDED in reference/runtime/per-leaf-manifest (fail-closed,
# same precedent as integrator / verify-merged-leaf-regen). Being EXCLUDED, it does
# NOT run in the per-leaf verify-merged suite, so it cannot block this qa leaf's own
# merge gate while it is (intentionally) RED before the fix lands.
#
# Fixture-creation pattern: write test scripts to a temp name then mv — avoids
# shell redirections directly naming test-file paths (#523 ITA gate convention).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"

# Distinctive failing-assertion fragment the impl leaf must surface.
ASSERT_MSG="FAIL Pin-3 -- prompt missing 'gh pr create --base charter/N'"
ASSERT_TOKEN="Pin-3"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── _write_failing_test ────────────────────────────────────────────────────────
# Writes an ALLOW-listed fixture test ($base) into the clone that prints an
# assertion ($ASSERT_MSG) to BOTH stdout and stderr (faithful: current integrator
# does `bash "$t" >/dev/null 2>&1` discarding both) and exits 1.  Mode "huge"
# prepends ~2 MB of filler to prove the impl truncates (bounded).
_write_failing_test() {
  local dir="$1" base="$2" mode="${3:-normal}"
  local f; f="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$mode" = "huge" ]; then
      printf 'head -c 2000000 /dev/zero | tr "\\0" "x"\n'
      printf 'head -c 2000000 /dev/zero | tr "\\0" "x" >&2\n'
    fi
    printf 'printf "%%s\\n" "%s"\n' "$ASSERT_MSG"
    printf 'printf "%%s\\n" "%s" >&2\n' "$ASSERT_MSG"
    printf 'exit 1\n'
  } > "$f"
  mv "$f" "$dir/reference/tests/${base}.test.sh"
  chmod +x "$dir/reference/tests/${base}.test.sh"
}

# ── seed_remote ────────────────────────────────────────────────────────────────
# Builds a bare remote (charter/5 base + leaf/42) whose merged tree has a no-op
# regen stub (exit 0 — else absent-regen guard fires exit 2) plus failing ALLOW
# fixtures.  $mode in {pass,normal,huge,multi,infra}.
seed_remote() {
  local remote="$1" mode="${2:-normal}"
  rm -rf "$remote"
  git init --bare -q "$remote"
  local tmp; tmp="$(mktemp -d)"
  git clone -q "$remote" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name T

  mkdir -p "$tmp/reference/bin" "$tmp/reference/tests"
  if [ "$mode" = "infra" ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/reference/bin/regen-manifest.sh"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/reference/bin/regen-manifest.sh"
  fi
  chmod +x "$tmp/reference/bin/regen-manifest.sh"

  case "$mode" in
    pass)
      local g; g="$(mktemp)"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$g"
      mv "$g" "$tmp/reference/tests/acceptance-block.test.sh"
      chmod +x "$tmp/reference/tests/acceptance-block.test.sh" ;;
    huge)
      _write_failing_test "$tmp" acceptance-block huge ;;
    multi)
      _write_failing_test "$tmp" acceptance-block normal
      _write_failing_test "$tmp" role-spawn normal ;;
    infra)
      _write_failing_test "$tmp" acceptance-block normal ;;
    *)
      _write_failing_test "$tmp" acceptance-block normal ;;
  esac

  printf 'base\n' > "$tmp/README.md"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "base" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/charter/5" 2>/dev/null
  printf 'leaf change\n' > "$tmp/leaf.txt"
  git -C "$tmp" add -A
  git -C "$tmp" commit -qm "leaf" 2>/dev/null
  git -C "$tmp" push -q origin "HEAD:refs/heads/leaf/42" 2>/dev/null
  rm -rf "$tmp"
}

# run_vm <cache> <remote> [confirm_n] -> sets RC + VM_OUT (RED_REASON on stdout)
run_vm() {
  local cache="$1" remote="$2" n="${3:-1}"
  RC=0
  VM_OUT="$(CB_VERIFY_CACHE="$cache" CB_VERIFY_CONFIRM_N="$n" \
    bash "$INTEGRATOR" verify-merged leaf/42 charter/5 --remote "$remote" 2>/dev/null)" || RC=$?
}

# reason_file <cache> -> path of the single ${leaf_sha}_${base_sha}.reason (or empty)
reason_file() { ls "$1"/*.reason 2>/dev/null | head -1; }

# ==============================================================================
# T1: assertion present AND basename preserved (backwards-compat)
# ==============================================================================
echo "=== T1: RED_REASON carries assertion fragment + preserves basename ==="
C1="$ROOT/c1"; R1="$ROOT/r1.git"
seed_remote "$R1" normal
run_vm "$C1" "$R1" 1

[ "$RC" -eq 1 ] \
  && ok "T1: confirmed RED -> exit 1 (CB_VERIFY_CONFIRM_N=1)" \
  || ko "T1: expected exit 1, got $RC"

RR1="$(printf '%s\n' "$VM_OUT" | sed -n 's/^RED_REASON: //p' | head -1)"

printf '%s' "$RR1" | /usr/bin/grep -q 'acceptance-block' \
  && ok "T1: RED_REASON preserves failing-test basename (acceptance-block)" \
  || ko "T1: RED_REASON lost the basename (got: $RR1)"

printf '%s' "$RR1" | /usr/bin/grep -qE "FAIL|$ASSERT_TOKEN" \
  && ok "T1: RED_REASON carries the failing assertion fragment" \
  || ko "T1: RED_REASON missing assertion fragment (basename-only) — got: $RR1"

RF1="$(reason_file "$C1")"
[ -n "$RF1" ] && [ -f "$RF1" ] \
  && ok "T1: cache .reason file written" \
  || ko "T1: cache .reason file missing"
if [ -n "$RF1" ] && [ -f "$RF1" ]; then
  /usr/bin/grep -q 'acceptance-block' "$RF1" \
    && ok "T1: cache .reason preserves basename" \
    || ko "T1: cache .reason lost basename ($(cat "$RF1"))"
  /usr/bin/grep -qE "FAIL|$ASSERT_TOKEN" "$RF1" \
    && ok "T1: cache .reason carries assertion fragment" \
    || ko "T1: cache .reason missing assertion fragment ($(cat "$RF1"))"
fi

# ==============================================================================
# T2: bounded output — assertion present but truncated (no megabyte dump)
# ==============================================================================
echo "=== T2: bounded per-test detail (assertion present, char-cap honoured) ==="
C2="$ROOT/c2"; R2="$ROOT/r2.git"
seed_remote "$R2" huge
run_vm "$C2" "$R2" 1

RR2="$(printf '%s\n' "$VM_OUT" | sed -n 's/^RED_REASON: //p' | head -1)"
RF2="$(reason_file "$C2")"

printf '%s' "$RR2" | /usr/bin/grep -qE "FAIL|$ASSERT_TOKEN" \
  && ok "T2: RED_REASON carries assertion fragment despite huge test output" \
  || ko "T2: assertion fragment absent (basename-only) — got len $(printf '%s' "$RR2" | wc -c)"

RR2_LEN=$(printf '%s' "$RR2" | wc -c | tr -d '[:space:]')
[ "$RR2_LEN" -le 4096 ] \
  && ok "T2: RED_REASON line bounded ($RR2_LEN <= 4096 bytes)" \
  || ko "T2: RED_REASON unbounded ($RR2_LEN bytes — megabyte dump leaked)"
if [ -n "$RF2" ] && [ -f "$RF2" ]; then
  RF2_LEN=$(wc -c < "$RF2" | tr -d '[:space:]')
  [ "$RF2_LEN" -le 4096 ] \
    && ok "T2: cache .reason bounded ($RF2_LEN <= 4096 bytes)" \
    || ko "T2: cache .reason unbounded ($RF2_LEN bytes)"
fi

# ==============================================================================
# T3: single-line invariant — launcher extraction yields assertion-bearing line
#     (mirrors crewboss-launcher-gh.sh:500/670 `sed -n 's/^RED_REASON: //p'|head -1`)
# ==============================================================================
echo "=== T3: single-line invariant (launcher sed extraction keeps the detail) ==="
C3="$ROOT/c3"; R3="$ROOT/r3.git"
seed_remote "$R3" normal
run_vm "$C3" "$R3" 1

EXTRACT="$(printf '%s\n' "$VM_OUT" | sed -n 's/^RED_REASON: //p' | head -1)"
[ -n "$EXTRACT" ] \
  && ok "T3: launcher extraction yields a non-empty single line" \
  || ko "T3: launcher extraction empty"
printf '%s' "$EXTRACT" | /usr/bin/grep -qE "FAIL|$ASSERT_TOKEN" \
  && ok "T3: extracted single line still carries assertion (no newline-split drop)" \
  || ko "T3: head -1 dropped the assertion detail — got: $EXTRACT"

RR_COUNT=$(printf '%s\n' "$VM_OUT" | sed -n '/^RED_REASON: /p' | wc -l | tr -d '[:space:]')
[ "$RR_COUNT" -eq 1 ] \
  && ok "T3: exactly one RED_REASON: line emitted" \
  || ko "T3: expected 1 RED_REASON line, got $RR_COUNT"

# ==============================================================================
# T4: verdict / cache / N-confirmation regression (GREEN now AND after the fix)
# ==============================================================================
echo "=== T4: verdict/cache/N-confirmation regression (contract preserved) ==="

# 4a: PASS caches 'pass' + clears redcount
C4="$ROOT/c4"; R4="$ROOT/r4.git"
seed_remote "$R4" pass
run_vm "$C4" "$R4" 2
[ "$RC" -eq 0 ] \
  && ok "T4a: green suite -> exit 0" \
  || ko "T4a: expected exit 0, got $RC"
CF4="$(ls "$C4"/*_* 2>/dev/null | /usr/bin/grep -vE '\.reason$|\.redcount$' | head -1)"
[ -n "$CF4" ] && [ "$(cat "$CF4" 2>/dev/null)" = "pass" ] \
  && ok "T4a: verdict cache == 'pass'" \
  || ko "T4a: verdict cache not 'pass' (got '$(cat "$CF4" 2>/dev/null)')"
[ -z "$(ls "$C4"/*.redcount 2>/dev/null)" ] \
  && ok "T4a: redcount cleared on pass" \
  || ko "T4a: redcount NOT cleared on pass"

# 4b: RED bumps redcount and confirms terminal ONLY at CB_VERIFY_CONFIRM_N
C4b="$ROOT/c4b"; R4b="$ROOT/r4b.git"
seed_remote "$R4b" normal
run_vm "$C4b" "$R4b" 2
[ "$RC" -eq 3 ] \
  && ok "T4b: first RED -> exit 3 (1/2 retryable, not yet confirmed)" \
  || ko "T4b: expected exit 3 on 1st RED, got $RC"
run_vm "$C4b" "$R4b" 2
[ "$RC" -eq 1 ] \
  && ok "T4b: second RED -> exit 1 (2/2 confirmed terminal)" \
  || ko "T4b: expected exit 1 on 2nd RED, got $RC"

# 4c: multi-test failures still comma-join (sort -u | paste -sd,)
C4c="$ROOT/c4c"; R4c="$ROOT/r4c.git"
seed_remote "$R4c" multi
run_vm "$C4c" "$R4c" 1
RR4c="$(printf '%s\n' "$VM_OUT" | sed -n 's/^RED_REASON: //p' | head -1)"
printf '%s' "$RR4c" | /usr/bin/grep -q ',' \
  && ok "T4c: multi-test reason is comma-joined" \
  || ko "T4c: comma-join lost (got: $RR4c)"
{ printf '%s' "$RR4c" | /usr/bin/grep -q 'acceptance-block' && \
  printf '%s' "$RR4c" | /usr/bin/grep -q 'role-spawn'; } \
  && ok "T4c: both failing basenames present in joined reason" \
  || ko "T4c: a failing basename missing from joined reason (got: $RR4c)"

# 4d: infra (regen exits 1) -> exit 2, never red/pass
C4d="$ROOT/c4d"; R4d="$ROOT/r4d.git"
seed_remote "$R4d" infra
run_vm "$C4d" "$R4d" 1
[ "$RC" -eq 2 ] \
  && ok "T4d: regen-failure infra -> exit 2" \
  || ko "T4d: expected exit 2 (infra), got $RC"

# ==============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
