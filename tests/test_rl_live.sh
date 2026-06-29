#!/usr/bin/env bash
# tests/test_rl_live.sh — RED-first rate-limit (RL) contract for charter #1004.
# Issue: #1041 (qa-engineer leaf; OWNS tests/). Merges FIRST, before the two
# implementation leaves:
#   - cache-etag-backoff (infra): one-fetch-per-tick in-memory cache + conditional
#     requests (`_cb_issue_list` fetches `-f sort=updated -f direction=desc`, stores
#     page-1 ETag, sends `If-None-Match`; a 304 == provably-unchanged list reused at
#     no primary-RL cost) + `/rate_limit` backoff — all in crewboss-launcher-gh.sh.
#   - executor-prcreate (executor): deterministic `cb_pr_create` helper shipped as
#     reference/runtime/cb-pr-create.sh (canonical -> /cbnet/cb-pr-create.sh).
#
# WHY this leaf exists (self-contained context for a cold reader):
#   The crewboss loop exhausts the GitHub REST rate-limit (5000/h authenticated) and
#   hits 0 remaining, after which `gh pr create` fails -> leaves silently lose PRs ->
#   review-stale -> blocked (observed #996, 2026-06-29: work done, PR never created at
#   RL=0). Root cause: `_cb_issue_list` is called ~20x/tick, each re-paginating >600
#   issues; per-leaf/per-charter `board get` loops add more; no ETag/conditional GETs;
#   CB_POLL=20s -> ~180 ticks/h. This file pins the contract the impl must satisfy.
#
# -------------------------------------------------------------------------------
# TEST-FIRST CONTRACT (read this before "fixing" a red):
#   The five impl-gating assertions (1-5) are EXPECTED RED against the current
#   launcher/helper — that is the POINT. They go GREEN only once the impl leaves land.
#   They live in the SOURCE/LIVE tier and are NOT run by the default invocation.
#
#   The default invocation runs the MOCK/STUB tier ONLY. The mock tier:
#     * is fully deterministic (PATH-stubbed gh; no network; no real launcher),
#     * proves the harness + the pass/fail discriminator for every assertion against
#       a reference stub that DOES satisfy the contract,
#     * MUST pass at this leaf's own merge (alongside `bash -n`).
#   This mirrors the proven #969 pagination-guard structure (fixture vs source mode).
#
# Modes (CB_RL_MODE):
#   mock   (default) : deterministic stub tier. GREEN at merge. No real source, no gh.
#   source           : impl-gating assertions vs the REAL launcher + helper artifacts
#                      (static design markers + behavioral helper contract). RED until
#                      the impl leaves land. Owned by those leaves at their merge.
#   live  (or source + token): in addition to `source`, when a GH token + CB_REPO are
#                      present the LIVE measurement tier runs and HARD-FAILS (does NOT
#                      skip) per Acceptance ("proven live, not on mock"). It measures
#                      the real `gh api /rate_limit` `used`/`remaining` deltas around
#                      real `cmd_run` ticks. RED until the impl leaves land.
#
# Acceptance (machine):  test: tests/test_rl_live.sh    check: bash -n tests/test_rl_live.sh
# -------------------------------------------------------------------------------

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE="${CB_RL_MODE:-mock}"

LAUNCHER="$ROOT/reference/runtime/crewboss-launcher-gh.sh"
# Helper: canonical deploy path first, repo reference second (sourced by absolute path).
HELPER_CANON="/cbnet/cb-pr-create.sh"
HELPER_REF="$ROOT/reference/runtime/cb-pr-create.sh"

pass=0; fail=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
ko()  { printf 'FAIL %s\n' "$*"; fail=$((fail+1)); }
info(){ printf 'info %s\n' "$*"; }

# ===========================================================================
# Reference stub helper — the EXACT pinned cb_pr_create contract, implemented so
# the mock tier can prove the discriminator that test 4 applies to the REAL helper.
#   - Callable: cb_pr_create <gh pr create args...> using CB_REPO.
#   - CB_RL_REMAINING_OVERRIDE bypasses `gh api /rate_limit` (deterministic injection).
#   - Knobs: CB_RL_FLOOR (default 1000), CB_PR_RETRY_MAX, CB_PR_BACKOFF_S.
#   - Loud-fail: exit 75 + stderr marker CB_PR_CREATE_FAILED when RL pressure persists
#     past CB_PR_RETRY_MAX (NO silent PR drop).
# This is bundled ONLY as the mock-tier reference; the SOURCE tier asserts against the
# real shipped helper, never this stub.
# ===========================================================================
_ref_cb_pr_create() {
  local floor="${CB_RL_FLOOR:-1000}"
  local max="${CB_PR_RETRY_MAX:-3}"
  local backoff="${CB_PR_BACKOFF_S:-2}"
  local tries=0 remaining
  while :; do
    if [ -n "${CB_RL_REMAINING_OVERRIDE:-}" ]; then
      remaining="$CB_RL_REMAINING_OVERRIDE"
    else
      remaining="$(gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo 0)"
    fi
    [ -n "$remaining" ] || remaining=0
    if [ "$remaining" -ge "$floor" ] 2>/dev/null; then
      gh pr create -R "${CB_REPO:-x/y}" "$@" && return 0
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge "$max" ]; then
      echo "CB_PR_CREATE_FAILED: rate-limit remaining=$remaining < floor=$floor after $tries attempt(s)" >&2
      return 75
    fi
    sleep "$backoff" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# assert_pr_create_contract <prefix> : drive the pinned test-4 command line against
# whatever cb_pr_create is currently in scope (ref stub in mock mode; real helper in
# source mode) and assert the loud-fail contract. RL pressure forced via override.
# ---------------------------------------------------------------------------
assert_pr_create_contract() {
  local prefix="$1" rc=0 out
  out="$(CB_RL_REMAINING_OVERRIDE=0 CB_PR_RETRY_MAX=1 CB_PR_BACKOFF_S=0 \
         cb_pr_create --title x --body y 2>&1)" || rc=$?
  if [ "$rc" -eq 75 ] && printf '%s' "$out" | grep -q 'CB_PR_CREATE_FAILED'; then
    ok "$prefix: RL=0 -> exit 75 + CB_PR_CREATE_FAILED (no silent PR drop)"
  else
    ko "$prefix: expected exit 75 + CB_PR_CREATE_FAILED, got rc=$rc out=[$out]"
  fi
}
assert_pr_create_healthy() {
  local prefix="$1" rc=0 out
  # Healthy RL (override well above floor) -> the create path must run, not throttle.
  out="$(CB_RL_REMAINING_OVERRIDE=5000 CB_RL_FLOOR=1000 CB_PR_RETRY_MAX=1 CB_PR_BACKOFF_S=0 \
         cb_pr_create --title x --body y 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'CB_PR_CREATE_FAILED'; then
    ok "$prefix: healthy RL -> create proceeds, no throttle/loud-fail"
  else
    ko "$prefix: healthy RL should create cleanly, got rc=$rc out=[$out]"
  fi
}

# ===========================================================================
# MOCK / STUB TIER — deterministic, GREEN at merge. Proves the harness + every
# discriminator against a reference that satisfies the contract.
# ===========================================================================
run_mock_tier() {
  echo "=== MOCK TIER (deterministic; proves the RL contract discriminators) ==="
  local TMP; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' RETURN
  local BIN="$TMP/bin"; mkdir -p "$BIN"

  # gh stub: a counting/snapshot stub.
  #   * `gh api /rate_limit ...`     -> emits CB_MOCK_REMAINING (default 5000) + bumps `used`
  #   * `gh api .../issues ...`      -> bumps a call counter; emits the snapshot fixture,
  #                                     honouring sort=updated when present (test 5).
  #   * `gh pr create ...`           -> success (exercised only on the healthy path)
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
ctr="${CB_MOCK_CTR:-/dev/null}"
sub="${1:-}"; arg2="${2:-}"
if [ "$sub" = "api" ]; then
  path=""
  for a in "$@"; do case "$a" in /*) path="$a"; break;; esac; done
  if printf '%s' "$path" | grep -q '/rate_limit'; then
    [ -f "${CB_MOCK_USED:-/dev/null}" ] && {
      u="$(cat "$CB_MOCK_USED" 2>/dev/null || echo 0)"; echo $((u+1)) > "$CB_MOCK_USED"; }
    rem="${CB_MOCK_REMAINING:-5000}"
    for ((i=1;i<=$#;i++)); do
      if [ "${!i}" = "-q" ]; then j=$((i+1)); f="${!j}"
        case "$f" in *remaining*) echo "$rem"; exit 0;; *used*) echo "0"; exit 0;; esac
      fi
    done
    echo "{\"resources\":{\"core\":{\"remaining\":$rem,\"used\":0,\"limit\":5000}}}"
    exit 0
  fi
  [ "$ctr" != /dev/null ] && { n="$(cat "$ctr" 2>/dev/null || echo 0)"; echo $((n+1)) > "$ctr"; }
  cat "${CB_MOCK_SNAPSHOT:-/dev/null}" 2>/dev/null || echo "[]"
  exit 0
fi
if [ "$sub" = "pr" ] && [ "$arg2" = "create" ]; then
  echo "https://github.com/x/y/pull/1"; exit 0
fi
echo "[]"; exit 0
STUB
  chmod +x "$BIN/gh"
  local OLD_PATH="$PATH"; export PATH="$BIN:$PATH"
  export CB_REPO="x/y"

  # --- self-check: the gh stub's RL + counter seams behave -------------------
  export CB_MOCK_CTR="$TMP/ctr"; export CB_MOCK_USED="$TMP/used"
  : > "$CB_MOCK_CTR"; : > "$CB_MOCK_USED"
  if [ "$(CB_MOCK_REMAINING=4242 gh api /rate_limit -q '.resources.core.remaining')" = "4242" ]; then
    ok "mock self-check: gh stub /rate_limit honours remaining + -q filter"
  else
    ko "mock self-check: gh stub /rate_limit seam broken"
  fi

  # =========================================================================
  # 1) REST-per-tick down multiples. Harness: count primary REST calls around a
  #    'tick'. Naive tick re-fetches the list on every call site; cached tick
  #    fetches ONCE. Assert the cached tick spends a small fraction (< 1/4).
  # =========================================================================
  echo "--- 1) REST-per-tick: cached tick spends a small fraction of the naive tick ---"
  export CB_MOCK_SNAPSHOT="$TMP/snap.json"
  echo '[{"number":1,"state":"OPEN","labels":[],"body":""}]' > "$CB_MOCK_SNAPSHOT"
  tick_naive() { local i; for i in $(seq 1 20); do gh api -X GET "/repos/$CB_REPO/issues" >/dev/null; done; }
  tick_cached(){ gh api -X GET "/repos/$CB_REPO/issues" >/dev/null; }   # one-fetch-per-tick
  : > "$CB_MOCK_CTR"; tick_naive;  local pre;  pre="$(cat "$CB_MOCK_CTR")"
  : > "$CB_MOCK_CTR"; tick_cached; local post; post="$(cat "$CB_MOCK_CTR")"
  if [ "$pre" -gt 0 ] && [ "$post" -gt 0 ] && [ $((post * 4)) -lt "$pre" ]; then
    ok "1 REST-per-tick discriminator: post($post) < pre($pre)/4 detected"
  else
    ko "1 REST-per-tick discriminator broken: pre=$pre post=$post"
  fi

  # =========================================================================
  # 2) `remaining` holds margin over a multi-tick run (worst tick > floor).
  # =========================================================================
  echo "--- 2) remaining holds margin (worst-tick remaining > floor) ---"
  local floor=1000 worst=999999 t r
  for t in 1 2 3 4 5; do
    r="$(CB_MOCK_REMAINING=$((5000 - t)) gh api /rate_limit -q '.resources.core.remaining')"
    [ "$r" -lt "$worst" ] && worst="$r"
  done
  if [ "$worst" -gt "$floor" ]; then
    ok "2 remaining-margin discriminator: worst-tick remaining=$worst > floor=$floor"
  else
    ko "2 remaining-margin discriminator broken: worst=$worst floor=$floor"
  fi

  # =========================================================================
  # 3) Backoff fires under pressure, NOT otherwise. Reference predicate:
  #    throttle iff remaining < floor.
  # =========================================================================
  echo "--- 3) backoff fires under pressure, not when healthy ---"
  _ref_should_throttle() { [ "${1:-0}" -lt "${2:-1000}" ]; }
  if _ref_should_throttle 50 1000 && ! _ref_should_throttle 4800 1000; then
    ok "3 backoff discriminator: throttles at remaining<floor, idle when healthy"
  else
    ko "3 backoff discriminator broken"
  fi

  # =========================================================================
  # 4) PR not lost under RL pressure — the PINNED helper contract. Assert the
  #    reference stub (which DOES satisfy the contract) loud-fails AND succeeds
  #    when healthy. (Source tier reruns this against the REAL helper.)
  # =========================================================================
  echo "--- 4) cb_pr_create contract (against reference stub) ---"
  cb_pr_create() { _ref_cb_pr_create "$@"; }
  assert_pr_create_contract "4 mock"
  assert_pr_create_healthy  "4 mock"
  unset -f cb_pr_create

  # =========================================================================
  # 5) Stale-snapshot correctness — a label change on a NON-newest-by-creation
  #    issue must surface next tick. RED against naive created-sort/first-page
  #    ETag (a 304 would mask it); GREEN only with sort=updated. Prove the
  #    discriminator: a sort=updated fetch floats the just-touched older issue.
  # =========================================================================
  echo "--- 5) stale-snapshot: sort=updated surfaces a touched older issue ---"
  cat > "$CB_MOCK_SNAPSHOT" <<'JSON'
[{"number":10,"state":"OPEN","labels":[{"name":"status:approved"}],"body":""},
 {"number":99,"state":"OPEN","labels":[],"body":""}]
JSON
  updated_sort_fetch() { gh api -X GET "/repos/$CB_REPO/issues" -f sort=updated -f direction=desc; }
  local snap; snap="$(updated_sort_fetch)"
  if printf '%s' "$snap" | grep -q '"number":10' \
     && printf '%s' "$snap" | grep -q 'status:approved'; then
    ok "5 stale-snapshot discriminator: relabeled older issue #10 visible via sort=updated"
  else
    ko "5 stale-snapshot discriminator broken: [$snap]"
  fi

  export PATH="$OLD_PATH"
  unset CB_MOCK_CTR CB_MOCK_USED CB_MOCK_SNAPSHOT CB_MOCK_REMAINING
}

# ===========================================================================
# SOURCE TIER — impl-gating. Static design markers + the behavioral helper
# contract against the REAL shipped artifacts. RED until the impl leaves land.
# ===========================================================================
run_source_tier() {
  echo
  echo "=== SOURCE TIER (impl-gating; RED until charter #1004 impl leaves land) ==="
  if [ ! -f "$LAUNCHER" ]; then
    ko "source: launcher not found at $LAUNCHER"; return
  fi

  # 1 + design: one-fetch-per-tick cache + conditional (ETag) requests in the
  #             shared `_cb_issue_list` fetch layer.
  echo "--- 1) launcher: per-tick cache + conditional (ETag) requests ---"
  if grep -Eq 'If-None-Match|If_None_Match|etag|ETag' "$LAUNCHER"; then
    ok "1 launcher sends conditional (ETag/If-None-Match) requests"
  else
    ko "1 launcher has NO ETag/If-None-Match conditional fetch (RL not reduced)"
  fi
  if grep -Eq '_cb_tick_cache|tick.?cache|CB_TICK_CACHE|_cb_issue_list_cache|one[- ]?fetch' "$LAUNCHER"; then
    ok "1 launcher has a per-tick in-memory issue-list cache"
  else
    ko "1 launcher has NO per-tick issue-list cache (re-paginates every call site)"
  fi

  # 2 + 3: /rate_limit backoff guard present in the launcher.
  echo "--- 2,3) launcher: /rate_limit backoff guard ---"
  if grep -q 'rate_limit' "$LAUNCHER"; then
    ok "2,3 launcher queries /rate_limit for backoff"
  else
    ko "2,3 launcher never queries /rate_limit (no remaining-margin/backoff guard)"
  fi
  # RL-SPECIFIC marker only — the bare words "defer"/"throttle" already appear in
  # the launcher for unrelated scheduling, so they MUST NOT match here (false-green).
  if grep -Eq 'CB_RL_FLOOR|CB_RL_REMAINING|rl_floor|rl_remaining|rl_backoff|_cb_rl_|_cb_backoff' "$LAUNCHER"; then
    ok "2,3 launcher implements an RL-keyed backoff/defer path under RL pressure"
  else
    ko "2,3 launcher has NO RL-keyed backoff/defer path under RL pressure"
  fi

  # 5: sort=updated fetch (so stale-snapshot correctness holds with ETag 304s).
  echo "--- 5) launcher: _cb_issue_list fetches sort=updated direction=desc ---"
  if grep -q 'sort=updated' "$LAUNCHER"; then
    ok "5 launcher fetch is sort=updated (touched older issues surface next tick)"
  else
    ko "5 launcher fetch is NOT sort=updated (created-sort + ETag would mask relabels)"
  fi

  # 4: behavioral helper contract against the REAL shipped cb-pr-create.sh.
  echo "--- 4) helper: real cb-pr-create.sh loud-fails under RL pressure ---"
  local helper=""
  if   [ -f "$HELPER_CANON" ]; then helper="$HELPER_CANON"
  elif [ -f "$HELPER_REF"   ]; then helper="$HELPER_REF"
  fi
  if [ -z "$helper" ]; then
    ko "4 helper missing: neither $HELPER_CANON nor $HELPER_REF exists"
  else
    if ! bash -n "$helper" 2>/dev/null; then
      ko "4 helper $helper failed bash -n"
    else
      ( set +e
        # shellcheck disable=SC1090
        source "$helper" 2>/dev/null
        if ! command -v cb_pr_create >/dev/null 2>&1; then
          echo "FAIL 4 helper $helper does not define cb_pr_create"; exit 1
        fi
        rc=0
        out="$(CB_REPO=x/y CB_RL_REMAINING_OVERRIDE=0 CB_PR_RETRY_MAX=1 CB_PR_BACKOFF_S=0 \
               cb_pr_create --title x --body y 2>&1)" || rc=$?
        if [ "$rc" -eq 75 ] && printf '%s' "$out" | grep -q 'CB_PR_CREATE_FAILED'; then
          echo "ok   4 real helper: RL=0 -> exit 75 + CB_PR_CREATE_FAILED (no silent drop)"
        else
          echo "FAIL 4 real helper: expected exit 75 + CB_PR_CREATE_FAILED, got rc=$rc out=[$out]"
          exit 1
        fi
      ) && ok "4 real helper cb_pr_create honours the loud-fail contract" \
         || ko "4 real helper cb_pr_create violates the loud-fail contract"
    fi
  fi
}

# ===========================================================================
# LIVE TIER — measures REAL rate-limit behavior. HARD-FAILS (does not skip) when a
# GH token + CB_REPO are present, per Acceptance ("proven live, not on mock").
# Armed only within source/live mode so the default merge run stays deterministic.
# RED until the impl leaves land.
# ===========================================================================
have_token() { [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; }
rl_used() { gh api /rate_limit -q '.resources.core.used' 2>/dev/null || echo ""; }
rl_remaining() { gh api /rate_limit -q '.resources.core.remaining' 2>/dev/null || echo ""; }

run_live_tier() {
  if ! { have_token && [ -n "${CB_REPO:-}" ]; }; then
    info "LIVE TIER not armed (need GH token + CB_REPO). source-tier markers stand."
    return
  fi
  echo
  echo "=== LIVE TIER (token + CB_REPO present — GATING, not skipping) ==="
  if [ ! -f "$LAUNCHER" ]; then ko "live: launcher missing"; return; fi

  local u0 u1 r_floor=1000
  u0="$(rl_used)"
  if [ -z "$u0" ]; then
    info "live: /rate_limit unreadable (network/credentials) — env, not artifact"
    return
  fi

  # 1) REST-per-tick: measure `used` delta around one real cmd_run tick.
  echo "--- live 1) used-delta around one cmd_run tick ---"
  CB_MAX_TICKS=1 CB_POLL=0 timeout 240 bash "$LAUNCHER" run >/dev/null 2>&1 || true
  u1="$(rl_used)"
  if [ -n "$u1" ] && [ "$u1" -ge "$u0" ] 2>/dev/null; then
    local delta=$((u1 - u0))
    if [ "$delta" -le 25 ]; then
      ok "live 1 one tick spent $delta primary calls (<=25 budget)"
    else
      ko "live 1 one tick spent $delta primary calls (>25 — re-paginating per call site)"
    fi
  else
    info "live 1 used counter not monotonic ($u0 -> ${u1:-?}) — env, not artifact"
  fi

  # 2) remaining holds margin after the tick.
  echo "--- live 2) remaining margin ---"
  local rem; rem="$(rl_remaining)"
  if [ -n "$rem" ] && [ "$rem" -gt "$r_floor" ] 2>/dev/null; then
    ok "live 2 remaining=$rem > floor=$r_floor after a tick"
  elif [ -n "$rem" ]; then
    ko "live 2 remaining=$rem fell to/under floor=$r_floor"
  else
    info "live 2 remaining unreadable — env, not artifact"
  fi

  # 4) PR-create path under live RL pressure: the REAL helper must loud-fail.
  echo "--- live 4) real helper loud-fail under forced RL pressure ---"
  local helper=""
  if   [ -f "$HELPER_CANON" ]; then helper="$HELPER_CANON"
  elif [ -f "$HELPER_REF"   ]; then helper="$HELPER_REF"; fi
  if [ -z "$helper" ]; then
    ko "live 4 helper missing (neither $HELPER_CANON nor $HELPER_REF)"
  else
    ( set +e
      # shellcheck disable=SC1090
      source "$helper" 2>/dev/null
      command -v cb_pr_create >/dev/null 2>&1 || { echo "no cb_pr_create"; exit 1; }
      rc=0
      out="$(CB_RL_REMAINING_OVERRIDE=0 CB_PR_RETRY_MAX=1 CB_PR_BACKOFF_S=0 \
             cb_pr_create --title x --body y 2>&1)" || rc=$?
      [ "$rc" -eq 75 ] && printf '%s' "$out" | grep -q 'CB_PR_CREATE_FAILED'
    ) && ok "live 4 real helper loud-fails (exit 75 + CB_PR_CREATE_FAILED)" \
       || ko "live 4 real helper did NOT loud-fail under RL pressure"
  fi
}

# ===========================================================================
# Driver
# ===========================================================================
echo "### tests/test_rl_live.sh — charter #1004 RL contract (mode=$MODE) ###"

# Syntax-gate the artifacts under test (cheap, always run).
if bash -n "$LAUNCHER" 2>/dev/null; then ok "bash -n launcher clean"; else ko "bash -n launcher FAILED"; fi

case "$MODE" in
  mock)
    run_mock_tier
    ;;
  source|live)
    run_mock_tier
    run_source_tier
    run_live_tier
    ;;
  *)
    ko "unknown CB_RL_MODE=$MODE (use mock|source|live)"
    ;;
esac

echo
printf '=== SUMMARY (mode=%s): %d passed, %d failed ===\n' "$MODE" "$pass" "$fail"
[ "$fail" -eq 0 ]
