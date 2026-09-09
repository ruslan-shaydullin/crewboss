# SECURITY-REVIEW: PASS (conditional) — charter #1274 token handling

**Reviewer:** leaf/1300 (security-reviewer)
**Charter:** #1274 — RL v2 dual-pool hardening
**Scope:** token handling across the jail `gh` shim (`reference/runtime/gh-shim.sh`, #1299),
the launcher RL guard v2 (`reference/runtime/crewboss-launcher-gh.sh`, #1298), and the P4
token-separation recipe. Sign-off here is a **prerequisite** for merging the deploy leaf
1274-p3-deploy (#1301) — **necessary but NOT sufficient**; #1301 additionally requires
explicit human operator approval.

Verdict: the **shipped code** (#1298 + #1299) is clean on token handling. Two items are
handed to the deploy leaf #1301 as **blocking pre-merge conditions** (F6, F4/F5) and one is
a **tracking follow-up** (F7). None block the shim/launcher code already merged.

---

## 1. GH_TOKEN never logged — PASS

`GH_TOKEN` appears in `gh-shim.sh` **only in comments** (lines 7, 27, 37); it is never read
into a variable, never interpolated, never written.

- `_gh_shim_log()` (line 38) is the single logging primitive; it writes to **stderr only**
  and is never called with argv (`$@`/`$*`) — every call site passes a statically
  constructed, token-free string (backoff reason, refresh counters, fatal notice).
- argv is forwarded **exclusively** via `"$real" "$@"` (line 198) and `_gh_shim_main "$@"`
  (line 207) — never through a logging/echo/printf path.
- The state writer (`_gh_shim_write_atomic`, lines 86–98) emits only the four RL integers.
- Machine check green: `! grep -nE "(echo|printf|log).*GH_TOKEN" reference/runtime/gh-shim.sh`.
- Launcher side confirms the same discipline ("No tokens are logged", launcher inventory
  block ~line 308).

## 2. Test seams gated by the positive sentinel CB_RL_TEST_MODE=1 — PASS

The override path (`gh-shim.sh` lines 152–156) is entered only when
`[ "${CB_RL_TEST_MODE:-0}" = "1" ]` **and** at least one override var is set. In production
the var is unset → defaults to `"0"` → the branch is dead and the real free
`gh api rate_limit` poll (lines 158–172) is taken instead. All four override vars
(`CB_RL_REMAINING_OVERRIDE`, `CB_RL_GQL_REMAINING_OVERRIDE`, `CB_RL_CORE_RESET_OVERRIDE`,
`CB_RL_GQL_RESET_OVERRIDE`) are read **only inside** that gated block — inert in production.
Machine check green: `grep -q CB_RL_TEST_MODE reference/runtime/gh-shim.sh`.

## 3. State file holds integer counters only — no token material — PASS

`_gh_shim_write_atomic` (lines 86–98) writes exactly four `key=value` lines:
`rl_core_remaining`, `rl_core_reset`, `rl_gql_remaining`, `rl_gql_reset`. The write is only
reached after a 4-way `_gh_shim_isint` guard (lines 176–177), so a non-integer/partial parse
never persists and never corrupts the file. No token, header, URL, or argv is written. The
launcher reader (`_cb_rl_state_get`) consumes the same integer-only schema. **PASS.**

## 4. State-file permissions — ADVISORY (actionable on #1301)

The shim sets **no explicit `umask`/`chmod`** on the temp file or the final state file
(lines 90–97); permissions inherit the ambient jail umask, which could be world-readable.
Severity is **LOW for the shim itself** because the file contains only non-secret RL
integers — world-readability is not a token leak. Still, to satisfy the review criterion and
be defensive:

- **#1301 (blocking-for-deploy):** create `$CB_HOME/run` as `0700` and ensure the rw bind
  exposes it non-world-readable; the `rl_state` file should land `0600`.
- **#1299 follow-up (nice-to-have):** add `umask 077` (or `chmod 600` on the temp before
  `mv`) inside `_gh_shim_write_atomic` so the guarantee is intrinsic to the shim, not
  dependent on deploy-time umask.

## 5. Cross-session leakage via the shared rw `run/` bind — BY DESIGN, scope it (#1301)

The shared rw `run/` bind carries **only** the four integer RL counters — intended
cross-session coordination, not a leak vector; no token/PII crosses. **Requirement for
#1301 (blocking-for-deploy):** the rw bind must be **scoped to the single `rl_state` file
(or a dedicated `run/` subdir)**, not a blanket host-`run/` mount, so unrelated host state
cannot leak between jail sessions. This aligns with #1301's stated "dedicated rw bind for
`$CB_HOME/run`" task — confirm the bind's blast radius at wiring time.

## 6. PATH-prepend / attacker-controlled binary — MEDIUM, pin CB_GH_REAL (blocking for #1301)

`_gh_shim_real()` (lines 46–74) resolves the real `gh` by walking `$PATH` and returning the
first executable `gh` that is not this script (symlink-resolved self-exclusion — correct).
Two residual risks in the jail:

- **(a) PATH-order hijack:** any writable PATH directory ordered *after* the shim but
  *before* the real `gh` lets a session drop a malicious `gh` that the shim will execute.
  This silently defeats the RL guard (and runs attacker code in the session's own context).
- **(b) Empty PATH element → CWD:** line 65 maps an empty PATH element to `p="."`, so an
  empty element makes the shim consider `./gh` in the **current working directory** — classic
  empty-element CWD injection.

**Mitigation already present:** the `CB_GH_REAL` explicit override (lines 47–50) short-circuits
the PATH walk to a pinned absolute path.

- **#1301 (blocking-for-deploy):** inject `CB_GH_REAL=/usr/bin/gh` (the real absolute path,
  verified against the manifest sha) into the jail env so resolution is **deterministic and
  PATH/CWD-independent**. This is the security fix that closes both (a) and (b).
- **#1299 follow-up (hardening):** skip empty PATH elements rather than treating them as `.`.

## 7. P4 token-separation recipe — PASS in principle, TRACKING GAP (follow-up)

The P4 deliverable was meant to be a new `status:blocked-on-user type:infra` sub-issue of
#1274. **No such issue exists** — the executor on #1298 was gated from `gh issue create`
(tech-lead only), so the recipe is captured in **PR #1309's body** instead. Reviewed there:

- Launcher process exports **only** `GH_TOKEN_LAUNCHER`; the spawn injects **only**
  `GH_TOKEN_SESSION` into the nsjail env and **never inherits** the launcher token.
- App path gives launcher/session distinct identities → independent pools, no cross-bill;
  the dual-source guard already assumes distinct identities (own-token poll vs shared-state
  file), so no code change is needed once tokens are separated.

Security assessment of the wiring: **sound** — no launcher↔session token cross-leak *as
described*, provided the nsjail invocation does not blanket-forward host env (no `-e` pass
of `GH_TOKEN_LAUNCHER`; explicit `--env GH_TOKEN_SESSION=...` only, matching the
`--env CB_RL_STATE_FILE=...` override-over-`-e` pattern already required by #1301).

**Follow-up (non-blocking for RL functionality; P1–P3 do not depend on P4):** a tech-lead
must open the sub-issue so the recipe is tracked and the "no launcher token in jail env"
requirement is enforced when token separation is actually implemented.

## 8. Human-approval gate on deploy leaf 1274-p3-deploy (#1301) — CONFIRMED

#1301's issue body prominently tracks the gate: *"HUMAN-APPROVAL GATE (rubric security
trigger, require_human_approval=true): this leaf's PR is blocked-on-human-approval — it must
NOT merge until an operator explicitly comments approval. Security-reviewer sign-off (#1300)
is necessary but not sufficient."* Visible and tracked on the issue that will carry the PR.
**Confirmed.**

---

## Sign-off

**PASS (conditional)** for token handling in the shipped shim (#1299) and launcher guard v2
(#1298): no token is logged or persisted, test seams are inert in production, and the shared
state carries integer counters only.

**Blocking review conditions handed to deploy leaf #1301** (enforced there, behind its own
human-approval gate) before it may merge:
1. **F6** — inject `CB_GH_REAL=<abs path to real gh>` into the jail env (deterministic real-`gh`
   resolution; closes PATH-order + empty-element/CWD hijack).
2. **F4/F5** — `run/` dir `0700`, `rl_state` `0600`, and a **scoped** rw bind limited to the
   RL state file/subdir (no blanket host-`run/` exposure).

**Follow-ups (non-blocking):** F4 intrinsic `umask 077` in the shim; F6 empty-PATH-element
skip in the shim; F7 tech-lead to open the P4 token-separation sub-issue of #1274.
