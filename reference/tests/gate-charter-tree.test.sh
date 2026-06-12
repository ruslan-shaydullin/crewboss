#!/usr/bin/env bash
# gate-charter-tree.test.sh — remote-branch scanning tests for gate-charter (issue #116).
# Class i: integration with bare git remote.
#
# Validates three failure modes that existed before the fix and one regression lock:
#
#  RED-a (scans wrong tree — pропуск грязного чартера):
#    bare-remote, charter/5 contains gate-bypass marker; CWD/--repo-dir clean.
#    gate-charter 5 --remote → MUST exit 1.
#    BEFORE fix: code grepped CWD → missed the dirty remote branch.
#
#  RED-b (false-RED from CWD — самосовпадение):
#    charter/5 clean; CWD contains a file with the bypass marker (e.g. old
#    crewboss-integrator.sh snapshot).
#    gate-charter 5 --remote → MUST exit 0.
#    BEFORE fix: marker-grep scanned CWD → always red on the real deploy box.
#
#  RED-c (самосовпадение в дереве ветки — carrier files):
#    charter/5 contains copies of all three carrier files of the integrator
#    repo (crewboss-integrator.sh, marker-gate.test.sh, charter-finale.test.sh)
#    as they look AFTER the fix; no other gate-bypass markers in the tree.
#    gate-charter 5 --remote → MUST exit 0.
#    Catches naive fix (just scan remote) without eliminating the literal from
#    carrier files, and half-fixes that exclude only one carrier file.
#
#  Regression lock (грязный файл по-прежнему блокирует):
#    charter/5 has carrier files (clean, post-fix) PLUS one genuinely dirty
#    file with the bypass marker.
#    gate-charter 5 --remote → MUST exit 1.
#    Ensures the gate is not weakened.
#
# Requires: bash, git.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="$HERE/../runtime/crewboss-integrator.sh"

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# ── presence check ────────────────────────────────────────────────────────────
if [ ! -f "$INTEGRATOR" ]; then
  ko "crewboss-integrator.sh absent from reference/runtime/"
  printf 'passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi
ok "integrator present"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Non-self-matching form of the bypass marker.
# At runtime this variable holds the real pattern; the source file does NOT
# contain the literal, so this test itself is safe to live in the repo tree.
MARKER="CREWBOSS_NO""GATE"   # evaluates to the real bypass marker

# ── helper: initialise a bare remote + working clone, create charter/5 ───────
# Usage: setup_remote <bare_dir> <work_dir>
# After call: work_dir is checked out on charter/5 (branch exists, nothing pushed yet).
setup_remote() {
  local bare="$1" work="$2"
  rm -rf "$bare" "$work"
  git init --bare -q "$bare"
  git clone -q "$bare" "$work" 2>/dev/null
  git -C "$work" config user.email t@t
  git -C "$work" config user.name  T
  printf 'base\n' > "$work/README.md"
  git -C "$work" add README.md
  git -C "$work" commit -qm "init"
  git -C "$work" push -q origin HEAD:refs/heads/main 2>/dev/null
  git -C "$work" checkout -q -b "charter/5" 2>/dev/null
}

# Push the current charter/5 working tree to the bare remote.
push_charter5() {
  local work="$1"
  git -C "$work" push -q origin "charter/5" 2>/dev/null
}

# =============================================================================
# RED-a: marker in remote charter/5; CWD clean → exit 1
# =============================================================================
echo "== RED-a: bypass marker in remote charter/5; CWD clean → exit 1 =="

BARE_A="$ROOT/bare_a.git"
WORK_A="$ROOT/work_a"
setup_remote "$BARE_A" "$WORK_A"

# Plant a dirty file in charter/5 tree
printf '# %s — do not commit\n' "$MARKER" > "$WORK_A/dirty.sh"
git -C "$WORK_A" add dirty.sh
git -C "$WORK_A" commit -qm "add dirty marker"
push_charter5 "$WORK_A"

# CWD is ROOT (clean); run gate with --remote pointing to the dirty bare repo.
if CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --remote "$BARE_A" >/dev/null 2>&1; then
  ko "RED-a: gate exit 0 — missed bypass marker in remote charter/5 branch"
else
  ok "RED-a: gate exit 1 (blocked dirty remote branch)"
fi

# =============================================================================
# RED-b: charter/5 clean; CWD has file with bypass marker → exit 0
# =============================================================================
echo "== RED-b: charter/5 clean; CWD file with bypass marker → exit 0 =="

BARE_B="$ROOT/bare_b.git"
WORK_B="$ROOT/work_b"
setup_remote "$BARE_B" "$WORK_B"
# charter/5 is clean — just README.md
push_charter5 "$WORK_B"

# Create a CWD that contains a file with the bypass marker literal
# (simulates the real deploy box where crewboss-integrator.sh itself used to
# contain the unguarded literal).
CWD_B="$ROOT/cwd_b"
mkdir -p "$CWD_B"
printf 'MARKER_PATTERN="%s"\n' "$MARKER" > "$CWD_B/crewboss-integrator.sh"

# Run gate-charter from the dirty CWD but scan --remote (the clean branch).
rc_b=0
(cd "$CWD_B" && \
  CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --remote "$BARE_B" >/dev/null 2>&1) || rc_b=$?

if [ "$rc_b" -eq 0 ]; then
  ok "RED-b: gate exit 0 (no false-RED from CWD bypass marker)"
else
  ko "RED-b: gate exit 1 (false-RED — scanned CWD instead of remote branch)"
fi

# =============================================================================
# RED-c: charter/5 has all 3 carrier files (post-fix, no literal) → exit 0
# =============================================================================
echo "== RED-c: charter/5 has post-fix carrier files → exit 0 =="

BARE_C="$ROOT/bare_c.git"
WORK_C="$ROOT/work_c"
setup_remote "$BARE_C" "$WORK_C"

# Copy the three carrier files (in their fixed, post-issue-#116 state) into
# the charter/5 tree.  After the fix none of them contains the bypass literal,
# so marker-grep must find 0 hits and exit 0.
mkdir -p "$WORK_C/reference/runtime" "$WORK_C/reference/tests"
cp "$HERE/../runtime/crewboss-integrator.sh" "$WORK_C/reference/runtime/"
cp "$HERE/marker-gate.test.sh"               "$WORK_C/reference/tests/"
cp "$HERE/charter-finale.test.sh"            "$WORK_C/reference/tests/"

git -C "$WORK_C" add reference/
git -C "$WORK_C" commit -qm "add post-fix carrier files"
push_charter5 "$WORK_C"

if CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --remote "$BARE_C" >/dev/null 2>&1; then
  ok "RED-c: gate exit 0 (post-fix carrier files cause no false-RED)"
else
  ko "RED-c: gate exit 1 (false-RED — carrier files still contain bypass literal)"
fi

# =============================================================================
# Regression: post-fix carrier files + genuinely dirty file → exit 1
# =============================================================================
echo "== Regression: carrier files (clean) + dirty file → exit 1 =="

BARE_R="$ROOT/bare_r.git"
WORK_R="$ROOT/work_r"
setup_remote "$BARE_R" "$WORK_R"

mkdir -p "$WORK_R/reference/runtime"
cp "$HERE/../runtime/crewboss-integrator.sh" "$WORK_R/reference/runtime/"
# A non-carrier file that genuinely contains the bypass marker
printf '# %s\n' "$MARKER" > "$WORK_R/bad_code.sh"
git -C "$WORK_R" add reference/ bad_code.sh
git -C "$WORK_R" commit -qm "carrier (clean) + dirty non-carrier"
push_charter5 "$WORK_R"

if CREWBOSS_MARKER_PATTERN="$MARKER" bash "$INTEGRATOR" \
    gate-charter 5 --remote "$BARE_R" >/dev/null 2>&1; then
  ko "Regression: gate exit 0 — missed genuinely dirty file in charter/5"
else
  ok "Regression: gate exit 1 (dirty non-carrier file correctly blocked)"
fi

# =============================================================================
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
