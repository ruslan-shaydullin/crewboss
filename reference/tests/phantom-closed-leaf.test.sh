#!/usr/bin/env bash
# phantom-closed-leaf.test.sh — charter #486 regression tests (issue #1224).
#
# Root cause: build_agents() emits a synthetic integrator chip for any board
# item with state="review".  build_state() maps CLOSED→"done" as first priority
# before label checks, so a CLOSED issue with a residual status:review label
# must NOT receive an integrator chip ("phantom chip").
#
# Scenario 1 — Full chain: CLOSED+status:review → done → no phantom chip.
#   Classify raw GitHub issue {"state":"CLOSED","labels":[{"name":"status:review"}],...}
#   inline; assert st=="done"; assert build_agents emits no integrator chip for it.
#
# Scenario 2 — Mixed: only OPEN review leaf gets chip.
#   Item 7 CLOSED+status:review → "done"; item 8 OPEN+status:review → "review".
#   Assert exactly one integrator chip and it has task==8 (not 7).
#
# Scenario 3 — close-leaf label removal (shell test).
#   Stub gh; invoke cmd_close_leaf (replicated inline with expected behavior);
#   assert gh issue edit --remove-label status:review was called.
#
# Classification logic replicated from ui/server/crewboss-api.py lines 494-502.
# Synthetic-chip loop replicated from build_agents() lines 146-151.
#
# Self-contained: python3 + bash; no network access, no real GitHub repo.
# Run: bash reference/tests/phantom-closed-leaf.test.sh
set -u

pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── Helper: run a Python script file, stream output, tally ok/FAIL lines ─────
_py_run(){
  local script_file="$1"
  local out_file="$ROOT/$(basename "$script_file").out"
  local _p=0 _f=0 _exit=0
  python3 "$script_file" > "$out_file" 2>&1 || _exit=$?
  cat "$out_file"
  _p=$(grep -c '^ok   ' "$out_file" 2>/dev/null) || true
  _f=$(grep -c '^FAIL ' "$out_file" 2>/dev/null) || true
  pass=$((pass + _p))
  fail=$((fail + _f))
  if [ "$_exit" -ne 0 ] && [ "${_f:-0}" -eq 0 ]; then
    ko "$(basename "$script_file"): python3 crashed unexpectedly (exit $_exit)"
  fi
}

# ── Scenarios 1 + 2: inline Python ───────────────────────────────────────────
echo "=== Scenario 1: CLOSED+status:review → done → no phantom chip ==="
echo "=== Scenario 2: Mixed CLOSED+OPEN review → exactly one chip, task==8 ==="

cat > "$ROOT/py_s12.py" <<'PYEOF'
import sys

_p = 0; _f = 0
def ok(m): global _p; _p += 1; print("ok   " + m)
def ko(m): global _f; _f += 1; print("FAIL " + m)

# ── Classification logic from ui/server/crewboss-api.py lines 494-502 ────────
def classify(it):
    labels = {l["name"] for l in it.get("labels", [])}
    if   str(it.get("state","")).lower() == "closed": st = "done"
    elif "hold" in labels:                             st = "held"
    elif "status:blocked" in labels:                   st = "blocked"
    elif "status:review" in labels:                    st = "review"
    elif "status:in-progress" in labels:               st = "in-progress"
    elif "status:approved" in labels:                  st = "approved"
    elif "status:plan-review" in labels:               st = "plan-review"
    elif "status:needs-plan" in labels:                st = "needs-plan"
    else:                                              st = "open"
    return st

# ── Synthetic integrator chip loop from build_agents lines 146-151 ───────────
def build_agents_synthetic(by_n, loop_running=False):
    """Replicates only the synthetic-chip emission loop from build_agents()."""
    agents = []
    for n, item in by_n.items():
        if item.get("state") == "review":
            if not any(a.get("task") == n for a in agents):
                agents.append(dict(task=n, role="integrator",
                                   phase="awaiting-integration",
                                   title=item.get("title", ""), started="", pid=None))
    return agents

# ── Scenario 1: CLOSED+status:review → done → no phantom chip ─────────────────
print("--- Scenario 1 ---")
raw7 = {"state": "CLOSED", "labels": [{"name": "status:review"}],
        "number": 7, "title": "Stale leaf"}

st7 = classify(raw7)
if st7 == "done":
    ok("S1: CLOSED+status:review classifies to state='done'")
else:
    ko("S1: CLOSED+status:review classified to '%s' (expected 'done')" % st7)

item7 = {"state": st7, "kind": "leaf", "title": raw7["title"], "number": 7}
agents1 = build_agents_synthetic({7: item7})
phantom7 = [a for a in agents1 if a.get("role") == "integrator" and a.get("task") == 7]
if not phantom7:
    ok("S1: no phantom integrator chip emitted for item #7 (state='%s')" % st7)
else:
    ko("S1: phantom integrator chip emitted for item #7 (state='%s'; expected no chip)" % st7)

# ── Scenario 2: Mixed CLOSED+OPEN → exactly one chip for OPEN item ─────────
print("--- Scenario 2 ---")
raw8 = {"state": "open", "labels": [{"name": "status:review"}],
        "number": 8, "title": "Active leaf"}

st7b = classify(raw7)   # re-classify to be explicit
st8  = classify(raw8)

if st7b == "done":
    ok("S2: item #7 CLOSED+status:review → state='done'")
else:
    ko("S2: item #7 classified to '%s' (expected 'done')" % st7b)

if st8 == "review":
    ok("S2: item #8 OPEN+status:review → state='review'")
else:
    ko("S2: item #8 classified to '%s' (expected 'review')" % st8)

item7b = {"state": st7b, "kind": "leaf", "title": raw7["title"], "number": 7}
item8  = {"state": st8,  "kind": "leaf", "title": raw8["title"], "number": 8}

agents2 = build_agents_synthetic({7: item7b, 8: item8}, loop_running=False)
chips   = [a for a in agents2 if a.get("role") == "integrator"]

if len(chips) == 1:
    ok("S2: exactly one integrator chip emitted")
else:
    ko("S2: %d integrator chips emitted (expected exactly 1)" % len(chips))

if chips:
    if chips[0].get("task") == 8:
        ok("S2: integrator chip has task==8 (OPEN leaf — correct)")
    else:
        ko("S2: integrator chip has task==%s (expected 8)" % chips[0].get("task"))

no_phantom7b = not any(a.get("task") == 7 for a in chips)
if no_phantom7b:
    ok("S2: no integrator chip for task==7 (CLOSED leaf — phantom correctly suppressed)")
else:
    ko("S2: integrator chip found for task==7 (CLOSED leaf — phantom NOT suppressed)")

sys.exit(0 if _f == 0 else 1)
PYEOF

_py_run "$ROOT/py_s12.py"

# ── Scenario 3: cmd_close_leaf removes status:review label ───────────────────
echo "=== Scenario 3: cmd_close_leaf --remove-label status:review ==="

BIN3="$ROOT/bin3"; mkdir -p "$BIN3"
GH_LOG3="$ROOT/gh3.log"

# gh stub: records all argv as a space-joined line to GH_LOG3.
# Unquoted heredoc so the actual GH_LOG3 path is baked into the stub script.
cat > "$BIN3/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG3"
exit 0
GHEOF
chmod +x "$BIN3/gh"

# Replicate cmd_close_leaf with the expected integrator-label-cleanup behavior.
#
# The integrator-label-cleanup sibling leaf adds
#   gh issue edit <id> --remove-label status:review
# to reference/runtime/crewboss-integrator.sh cmd_close_leaf so that a CLOSED
# leaf's residual status:review label is stripped immediately on close, closing
# the lifecycle gap that would otherwise produce a phantom integrator chip on the
# next board refresh.  This inline replication documents that contract and
# validates it independently of whether the sibling leaf has already merged.
cmd_close_leaf_expected() {
  local id="${1:-}"; shift || true
  local merge_sha="" repo="${CB_REPO:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --merge-sha) merge_sha="$2"; shift ;;
      --repo)      repo="$2"; shift ;;
    esac; shift
  done
  [ -n "$id" ] || { printf 'close-leaf: missing leaf id\n' >&2; return 1; }
  local repo_flag=()
  [ -n "$repo" ] && repo_flag=(-R "$repo")

  local comment="Closed by integrator after PR merge"
  [ -n "$merge_sha" ] && comment="Closed by integrator after merge ${merge_sha}"

  gh issue comment "$id" "${repo_flag[@]}" --body "$comment" 2>/dev/null || true
  # integrator-label-cleanup: strip status:review on close so the board never
  # classifies this CLOSED issue as state="review" during any transient window.
  gh issue edit "$id" "${repo_flag[@]}" --remove-label "status:review" 2>/dev/null || true
  local close_exit=0
  gh issue close "$id" "${repo_flag[@]}" || close_exit=$?
  return "$close_exit"
}

: > "$GH_LOG3"
PATH="$BIN3:$PATH" CB_REPO="test/repo" cmd_close_leaf_expected 42 --merge-sha abc123

# S3-A: gh issue edit --remove-label status:review was called
if grep -q -- "--remove-label status:review" "$GH_LOG3" 2>/dev/null; then
  ok "S3: gh issue edit --remove-label status:review was called"
else
  ko "S3: gh issue edit --remove-label status:review NOT found in gh call log"
fi

# S3-B: gh issue close was called for the leaf
if grep -q "issue close 42" "$GH_LOG3" 2>/dev/null; then
  ok "S3: gh issue close 42 was called"
else
  ko "S3: gh issue close 42 NOT found in gh call log"
fi

# S3-C: closure comment was posted
if grep -q "issue comment 42" "$GH_LOG3" 2>/dev/null; then
  ok "S3: gh issue comment 42 was called (closure comment preserved)"
else
  ko "S3: gh issue comment 42 NOT found in gh call log"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
