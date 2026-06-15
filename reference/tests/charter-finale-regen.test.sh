#!/usr/bin/env bash
# charter-finale-regen.test.sh — #206 Part A: manifest sha-lock auto-regen,
# persisted as a COMMIT at the charter→main finale.
#
# Class ii (integration): drives the REAL crewboss-integrator.sh regen-persist
# subcommand + the REAL reference/bin/regen-manifest.sh tool against throwaway
# bare git remotes (anti-reimplementation — we call the subcommand, we do NOT
# re-implement clone/regen/push in the test).
#
# Proves the [GROUND] A-persistence spike (concept #200 — prove by RUNNING, not
# by reasoning): the regen-commit is reachable from MAIN after the charter→main
# merge AND the post-merge MAIN tree's sha-lock is GREEN. The assertion is on the
# TARGET branch (main), NOT an ephemeral clone — that is the whole point of the
# stage-3 blocker (a regen thrown away in a verdict-only clone leaves canon stale).
#
# Tests:
#   T1 regen tool — a drifted canonical sha is refreshed to match the file.
#   T2 regen tool — a MISSING canonical file is NOT masked (sha-lock stays RED),
#                   so regen is sound, not a tautology.
#   T3 idempotent — regen-persist on an already-fresh charter/C = no-op (no new
#                   commit pushed) → safe to call every finale tick.
#   T4 A-PERSISTENCE — charter/C changes a canonical runtime file WITHOUT a
#                   manifest update; WITHOUT the fix the post-merge MAIN tree's
#                   sha-lock is RED; after regen-persist + the (human) charter→main
#                   merge, the post-merge MAIN tree's sha-lock is GREEN and the
#                   regen commit is reachable from main.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
INTEGRATOR="${INTEGRATOR_OVERRIDE:-$HERE/../runtime/crewboss-integrator.sh}"
REGEN_TOOL="$HERE/../bin/regen-manifest.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

# sha_lock_check <repo_root> — mirrors runtime-manifest.test.sh Test 3 EXACTLY:
# for each status=canonical row the file must exist AND sha256 must match.
# Returns 0 = green (manifest matches tree), 1 = red (drift or missing file).
sha_lock_check() {
  local rr="$1" rp sha st pu full actual rc=0
  while IFS=$'\t' read -r rp sha st pu; do
    case "${rp:-}" in ''|'#'*) continue ;; esac
    [ "${st:-}" = "canonical" ] || continue
    full="$rr/$rp"
    if [ ! -f "$full" ]; then rc=1; continue; fi
    actual=$(sha256sum "$full" | cut -d' ' -f1)
    [ "$actual" = "$sha" ] || rc=1
  done < "$rr/reference/runtime-manifest.tsv"
  return "$rc"
}

# seed_worktree <dir> <runtime-file-content> [stale]
#   Builds a minimal crewboss tree: one canonical runtime file + the regen tool +
#   a manifest. With "stale", the manifest sha is deliberately wrong (simulates a
#   leaf that changed the file but did not refresh the sha-lock).
seed_worktree() {
  local wd="$1" content="$2" mode="${3:-fresh}"
  mkdir -p "$wd/reference/runtime" "$wd/reference/bin"
  cp "$REGEN_TOOL" "$wd/reference/bin/regen-manifest.sh"
  chmod +x "$wd/reference/bin/regen-manifest.sh"
  printf '%s\n' "$content" > "$wd/reference/runtime/sample.sh"
  local s
  if [ "$mode" = "stale" ]; then
    s="0000000000000000000000000000000000000000000000000000000000000000"
  else
    s=$(sha256sum "$wd/reference/runtime/sample.sh" | cut -d' ' -f1)
  fi
  {
    printf '# fixture runtime-manifest (charter-finale-regen.test.sh)\n'
    printf 'reference/runtime/sample.sh\t%s\tcanonical\tsample runtime file\n' "$s"
  } > "$wd/reference/runtime-manifest.tsv"
}

# =============================================================================
# T1 + T2: regen tool unit — refresh drift, never mask a missing file
# =============================================================================
echo "=== T1/T2: regen tool — refresh drift, never mask missing ==="
U="$ROOT/unit"
seed_worktree "$U" "echo hello" stale
# add a second canonical row whose file does NOT exist (missing)
printf 'reference/runtime/gone.sh\tabc123\tcanonical\tmissing file\n' \
  >> "$U/reference/runtime-manifest.tsv"
sha_lock_check "$U" && ko "T1 precondition: expected RED before regen (stale sha)" \
                    || ok "T1 precondition: sha-lock RED before regen (stale)"
( cd "$U" && bash reference/bin/regen-manifest.sh ) >/dev/null 2>&1
# After regen: sample.sh row refreshed (green for that row) but gone.sh still
# missing → overall sha-lock stays RED (regen did not mask the deletion).
realsha=$(sha256sum "$U/reference/runtime/sample.sh" | cut -d' ' -f1)
grep -q "reference/runtime/sample.sh	$realsha	canonical" "$U/reference/runtime-manifest.tsv" \
  && ok "T1: drifted canonical sha refreshed to match file" \
  || ko "T1: sample.sh sha NOT refreshed"
grep -q "reference/runtime/gone.sh	abc123	canonical" "$U/reference/runtime-manifest.tsv" \
  && ok "T2: missing canonical file NOT masked (stale row preserved → sha-lock stays RED)" \
  || ko "T2: missing-file row was altered (regen masked a deletion)"

# =============================================================================
# T3: idempotent — regen-persist on a fresh charter/C is a no-op (no new commit)
# =============================================================================
echo "=== T3: regen-persist idempotent on fresh manifest (no new commit) ==="
BARE3="$ROOT/remote3.git"; git init --bare -q "$BARE3"
W3="$(mktemp -d)"
git clone -q "$BARE3" "$W3"
git -C "$W3" config user.email t@t; git -C "$W3" config user.name T
seed_worktree "$W3" "echo fresh" fresh
git -C "$W3" add -A; git -C "$W3" commit -qm base
git -C "$W3" push -q origin HEAD:refs/heads/main
git -C "$W3" push -q origin HEAD:refs/heads/charter/333
rm -rf "$W3"
before3=$(git ls-remote "$BARE3" refs/heads/charter/333 | awk '{print $1}')
rc3=0; bash "$INTEGRATOR" regen-persist 333 --remote "$BARE3" >/dev/null 2>&1 || rc3=$?
after3=$(git ls-remote "$BARE3" refs/heads/charter/333 | awk '{print $1}')
[ "$rc3" -eq 0 ] && ok "T3: regen-persist exit 0 on fresh manifest" \
                 || ko "T3: regen-persist exit $rc3 (expected 0)"
[ "$before3" = "$after3" ] && ok "T3: charter/333 HEAD unchanged (no-op, no churn)" \
                           || ko "T3: charter/333 advanced ($before3 → $after3) — not idempotent"

# =============================================================================
# T4: A-PERSISTENCE — proven on MAIN, not a clone
# =============================================================================
echo "=== T4: A-persistence — regen-commit reachable from MAIN, post-merge sha-lock GREEN ==="
BARE="$ROOT/remote.git"; git init --bare -q "$BARE"
W="$(mktemp -d)"
git clone -q "$BARE" "$W"
git -C "$W" config user.email t@t; git -C "$W" config user.name T
# main: fresh manifest (sha matches sample.sh=v1)
seed_worktree "$W" "echo v1" fresh
git -C "$W" add -A; git -C "$W" commit -qm "base: main with fresh manifest"
git -C "$W" push -q origin HEAD:refs/heads/main
# charter/777: change the canonical runtime file WITHOUT refreshing the sha-lock
printf 'echo v2 CHANGED\n' > "$W/reference/runtime/sample.sh"
git -C "$W" add -A
git -C "$W" commit -qm "leaf: change runtime file, manifest sha NOT updated (drift)"
git -C "$W" push -q origin HEAD:refs/heads/charter/777
rm -rf "$W"

# Step 1 — WITHOUT the fix: simulate the human charter→main merge and assert the
# post-merge MAIN tree's sha-lock is RED (this is the bug the leaf must kill).
V1="$(mktemp -d)"; git clone -q "$BARE" "$V1"
git -C "$V1" config user.email t@t; git -C "$V1" config user.name T
git -C "$V1" checkout -q main
git -C "$V1" merge -q --no-edit origin/charter/777 2>/dev/null
sha_lock_check "$V1" \
  && ko "T4 precondition: post-merge MAIN sha-lock GREEN (expected RED without fix)" \
  || ok "T4 precondition: post-merge MAIN sha-lock RED without regen (drift confirmed)"
rm -rf "$V1"

# Step 2 — run the charter-finale regen path (the REAL subcommand).
rc4=0; bash "$INTEGRATOR" regen-persist 777 --remote "$BARE" >/dev/null 2>&1 || rc4=$?
[ "$rc4" -eq 0 ] && ok "T4: regen-persist exit 0 (committed + pushed to charter/777)" \
                 || ko "T4: regen-persist exit $rc4 (expected 0)"

# Step 3 — the (human) charter→main merge now carries the regen commit. Assert on
# the TARGET branch (main): sha-lock GREEN + regen commit reachable from main.
V2="$(mktemp -d)"; git clone -q "$BARE" "$V2"
git -C "$V2" config user.email t@t; git -C "$V2" config user.name T
git -C "$V2" checkout -q main
git -C "$V2" merge -q --no-edit origin/charter/777 2>/dev/null
sha_lock_check "$V2" \
  && ok "T4: post-merge MAIN sha-lock GREEN (regen persisted onto canon)" \
  || ko "T4: post-merge MAIN sha-lock still RED — regen did NOT persist onto main"
git -C "$V2" log --oneline | grep -q "regen sha-lock at charter-#777" \
  && ok "T4: regen commit reachable from MAIN (real commit, not ephemeral)" \
  || ko "T4: regen commit NOT reachable from main"
# belt-and-suspenders: the manifest sha on main now equals sample.sh=v2's sha
v2sha=$(sha256sum "$V2/reference/runtime/sample.sh" | cut -d' ' -f1)
grep -q "reference/runtime/sample.sh	$v2sha	canonical" "$V2/reference/runtime-manifest.tsv" \
  && ok "T4: MAIN manifest sha == merged sample.sh sha (manifest==tree)" \
  || ko "T4: MAIN manifest sha != file sha after merge"
rm -rf "$V2"

# =============================================================================
echo
printf '=== SUMMARY: %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
