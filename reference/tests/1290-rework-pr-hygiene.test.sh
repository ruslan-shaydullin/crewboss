#!/usr/bin/env bash
# 1290-rework-pr-hygiene.test.sh — charter #1290 / issue #1302 (qa-engineer test-writer leaf).
#
# P3 of charter #1290: the rework-respawn path must stop leaving a graveyard of open
# PRs for one leaf (the incident: rework of #1281 spawned #1286/#1288/#1289, none of
# the superseded ones ever closed). rework PR creation is routed through cb_pr_create,
# which — AFTER it learns the new PR number N — closes every OTHER open PR of the SAME
# leaf (`leaf/<rid>-*` and `rework/<rid>-*` heads) with a comment "superseded by #N",
# and NEVER closes the new PR itself. The leaf-head creation path is unaffected, and
# the PINNED RL contract (return gh's exit code on success; 75 + CB_PR_CREATE_FAILED on
# RL loud-fail) stays intact.
#
# HARNESS: source the REAL reference/runtime/cb-pr-create.sh and drive cb_pr_create with
# a PATH-stubbed gh. No network.
#
# CONVENTION (tests-first, runnable standalone / GREEN now):
#   * REGRESSION — the pinned cb_pr_create contract (tests/test_rl_live.sh test 4) is
#     asserted NOW against the real helper and MUST stay green.
#   * NEW-behaviour — the superseded-close sweep is gated behind the `superseded` marker
#     in cb-pr-create.sh. Before the P3 impl lands it SKIPs (never a silent pass); once
#     it lands it asserts the full hygiene contract.
#
# CLASSIFICATION: EXCLUDED in reference/runtime/per-leaf-manifest — sources the runtime
# helper and drives a stubbed gh (helper-context), same class as rework-contract.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PR_CREATE="$HERE/../runtime/cb-pr-create.sh"

pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
sk(){ skip=$((skip+1)); printf 'SKIP %s\n' "$1"; }

if [ ! -f "$PR_CREATE" ]; then
  sk "cb-pr-create.sh absent — helper not integrated; all cases skipped"
  printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"; exit 0
fi

# Feature probe: does the helper carry the superseded-close sweep?
SUPERSEDE_PRESENT=0
grep -q 'superseded' "$PR_CREATE" 2>/dev/null && SUPERSEDE_PRESENT=1

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
BIN="$ROOT/bin"; mkdir -p "$BIN"
CLOSE_LOG="$ROOT/close.log"; CREATE_LOG="$ROOT/create.log"; COMMENT_LOG="$ROOT/comment.log"
export CLOSE_LOG CREATE_LOG COMMENT_LOG

# Open-PR fixture the gh stub serves for `pr list` (rid=42 has 2 prior siblings; the
# new PR is #777; #200 is an UNRELATED leaf and must never be touched).
PRLIST_JSON="$ROOT/prlist.json"
cat > "$PRLIST_JSON" <<'JSON'
[
  {"number":100,"headRefName":"leaf/42-old","state":"OPEN"},
  {"number":101,"headRefName":"rework/42-prev","state":"OPEN"},
  {"number":777,"headRefName":"rework/42-new","state":"OPEN"},
  {"number":200,"headRefName":"leaf/99-unrelated","state":"OPEN"}
]
JSON
export PRLIST_JSON

# ── gh stub: pr create / pr list / pr close / pr comment ───────────────────────────
# `pr create` echoes the canonical new-PR URL (#777) and exits with the code chosen via
# GH_CREATE_RC (default 0) so we can prove "return gh's exit code on success".
cat > "$BIN/gh" << 'GHEOF'
#!/usr/bin/env bash
obj="$1"; verb="$2"; shift 2
case "$obj $verb" in
  "pr create")
    printf 'pr create %s\n' "$*" >> "$CREATE_LOG"
    printf 'https://github.com/o/r/pull/%s\n' "${GH_NEW_PR:-777}"
    exit "${GH_CREATE_RC:-0}" ;;
  "pr list")
    # Serve the open-PR set; ignore filter flags (impl filters client-side).
    cat "$PRLIST_JSON" ;;
  "pr close")
    n="$1"; shift; cmt=""
    while [ $# -gt 0 ]; do case "$1" in --comment|-c) cmt="$2"; shift ;; esac; shift; done
    printf '%s\n' "$n" >> "$CLOSE_LOG"
    [ -n "$cmt" ] && printf '%s\t%s\n' "$n" "$cmt" >> "$COMMENT_LOG"
    exit 0 ;;
  "pr comment")
    n="$1"; shift; body=""
    while [ $# -gt 0 ]; do case "$1" in --body|-b) body="$2"; shift ;; esac; shift; done
    printf '%s\t%s\n' "$n" "$body" >> "$COMMENT_LOG"
    exit 0 ;;
  "api")
    # /rate_limit probe (should not be hit when CB_RL_REMAINING_OVERRIDE is set)
    printf '5000\n' ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$BIN/gh"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T1 (REGRESSION): pinned RL contract — loud-fail on RL=0 =="
# ═══════════════════════════════════════════════════════════════════════════════
rc=0
out="$( PATH="$BIN:$PATH" CB_REPO="o/r" CB_RL_REMAINING_OVERRIDE=0 \
        CB_RL_FLOOR=1000 CB_PR_RETRY_MAX=1 CB_PR_BACKOFF_S=0 \
        bash -c 'source "$0"; cb_pr_create --head rework/42-new --base charter/1290 --title x --body y' \
        "$PR_CREATE" 2>&1 )" || rc=$?
if [ "$rc" -eq 75 ] && printf '%s' "$out" | grep -q 'CB_PR_CREATE_FAILED'; then
  ok "T1: RL=0 -> exit 75 + CB_PR_CREATE_FAILED (no silent PR drop)"
else
  ko "T1: RL=0 expected exit 75 + CB_PR_CREATE_FAILED, got rc=$rc out=[$out]"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T2 (REGRESSION): healthy RL -> returns gh's exit code =="
# ═══════════════════════════════════════════════════════════════════════════════
rc=0
out="$( PATH="$BIN:$PATH" CB_REPO="o/r" CB_RL_REMAINING_OVERRIDE=5000 \
        CB_RL_FLOOR=1000 GH_CREATE_RC=0 \
        bash -c 'source "$0"; cb_pr_create --head leaf/42-new --base charter/1290 --title x --body y' \
        "$PR_CREATE" 2>&1 )" || rc=$?
[ "$rc" -eq 0 ] \
  && ok "T2: healthy RL, gh exit 0 -> cb_pr_create returns 0 (gh's code passed through)" \
  || ko "T2: healthy RL expected rc=0, got rc=$rc out=[$out]"
grep -q '^pr create ' "$CREATE_LOG" 2>/dev/null \
  && ok "T2: healthy RL -> gh pr create actually invoked" \
  || ko "T2: healthy RL -> gh pr create NOT invoked"

# T2b — non-zero gh exit is propagated verbatim
rc=0
PATH="$BIN:$PATH" CB_REPO="o/r" CB_RL_REMAINING_OVERRIDE=5000 CB_RL_FLOOR=1000 GH_CREATE_RC=7 \
  bash -c 'source "$0"; cb_pr_create --head leaf/42-x --base charter/1290 --title x --body y >/dev/null 2>&1' \
  "$PR_CREATE" || rc=$?
[ "$rc" -eq 7 ] \
  && ok "T2b: gh exit 7 -> cb_pr_create returns 7 (exact passthrough)" \
  || ko "T2b: gh exit 7 expected rc=7, got rc=$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "== T3 (NEW): rework PR closes superseded siblings of the same leaf =="
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SUPERSEDE_PRESENT" -ne 1 ]; then
  sk "T3: superseded-close not present in cb-pr-create.sh — P3 impl pending; hygiene assertions skipped"
else
  : > "$CLOSE_LOG"; : > "$CREATE_LOG"; : > "$COMMENT_LOG"
  rc=0
  PATH="$BIN:$PATH" CB_REPO="o/r" CB_RL_REMAINING_OVERRIDE=5000 CB_RL_FLOOR=1000 GH_NEW_PR=777 \
    bash -c 'source "$0"; cb_pr_create --head rework/42-new --base charter/1290 --title x --body y >/dev/null 2>&1' \
    "$PR_CREATE" || rc=$?
  [ "$rc" -eq 0 ] \
    && ok "T3: rework create still returns gh's exit code (0) with the sweep active" \
    || ko "T3: rework create returned rc=$rc (sweep must not break the pinned success contract)"
  # Prior siblings of rid=42 closed
  grep -qx '100' "$CLOSE_LOG" 2>/dev/null && grep -qx '101' "$CLOSE_LOG" 2>/dev/null \
    && ok "T3: prior siblings (leaf/42-old #100, rework/42-prev #101) CLOSED" \
    || ko "T3: prior siblings NOT closed (close.log: $(tr '\n' ' ' < "$CLOSE_LOG" 2>/dev/null))"
  # New PR never closes itself
  grep -qx '777' "$CLOSE_LOG" 2>/dev/null \
    && ko "T3: new PR #777 was WRONGLY closed (must never close itself)" \
    || ok "T3: new PR #777 NOT closed (never closes itself)"
  # Unrelated leaf untouched
  grep -qx '200' "$CLOSE_LOG" 2>/dev/null \
    && ko "T3: unrelated PR #200 (leaf/99) WRONGLY closed (must scope to same leaf)" \
    || ok "T3: unrelated PR #200 untouched (sweep scoped to the same leaf id)"
  # superseded-by comment references the new PR number
  grep -q 'superseded by #777' "$COMMENT_LOG" 2>/dev/null \
    && ok "T3: superseded PRs commented 'superseded by #777'" \
    || ko "T3: 'superseded by #777' comment missing (comment.log: $(tr '\n' ' ' < "$COMMENT_LOG" 2>/dev/null))"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo
printf 'passed=%d failed=%d skipped=%d\n' "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
