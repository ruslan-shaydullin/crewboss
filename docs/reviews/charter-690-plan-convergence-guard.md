# Review: Charter #690 — Plan-convergence approve gate

**Reviewer leaf:** #1185  
**Reviewed leaves:** #1183 (backend), #1184 (UI); tests by #1182  
**Verdict:** ✅ APPROVED — all machine acceptance checks pass

---

## Machine acceptance checks

| Check | Command | Result |
|-------|---------|--------|
| 1 | `bash /work/tests/690-tests-plan-convergence-guard.test.sh` | 13/13 PASS |
| 2 | `cd /work/ui/app && npx tsc --noEmit` | exit 0 |
| 3 | `assert '—' in crewboss-api.py` | em-dash OK |
| 4 | `assert plan_convergence_active >= 2 in App.tsx + Request changes present` | UI OK |

---

## Backend guard — `/work/ui/server/crewboss-api.py` (leaf #1183)

**Fresh evaluation (bypass-proof):**
- ✅ `_org = read_json(os.path.join(CB_TEAM, "org.json"), {})` — reads org.json fresh on every call.
- ✅ `sh(["gh", "issue", "view", n, "-R", REPO, "--json", "labels"])` — fetches live GitHub labels on every call, not cached board state.

**Em-dash in guard message:**
- ✅ Guard returns `{"ok": False, "msg": f"plan-convergence in progress — {_plan_review_role} must agree before approve"}` using U+2014 `—` (one codepoint, not the three-byte mojibake â^@^T).

**`build_state()` — `plan_convergence_active` field:**
- ✅ `if st == "plan-review": plan_convergence_active = "plan:agreed" not in labels` — True when status:plan-review and plan:agreed absent.
- ✅ `else: plan_convergence_active = False` — False for all non-plan-review items.
- ✅ Field explicitly present in every board item (no absent-key ambiguity).

**No new imports:**
- ✅ `CB_TEAM` and `read_json` already defined earlier in the module; `sh` likewise.

---

## TypeScript UI — `api.ts` and `App.tsx` (leaf #1184)

**`api.ts` — Task type:**
- ✅ `plan_convergence_active?: boolean  // #690 - charter only` added at line 16, after `finale_pr` (line 15), following the established pattern (`rework_n`, `git_status`, `blast_radius`, `finale_pr`).

**Site 1 — CharterCard header (~line 833):**
- ✅ `{c && c.state === 'plan-review' && !c.plan_convergence_active && <> ... </>}` — both Approve plan and Request changes buttons hidden together when convergence active.
- ✅ `{c && c.state === 'plan-review' && c.plan_convergence_active && (<span className="dim">plan-convergence in progress</span>)}` — status span shown instead.

**Site 2 — TaskDrawer actions (~line 1297):**
- ✅ `{task.state === 'plan-review' && !task.plan_convergence_active && (<> <button>Approve plan</button> <button>Request changes</button> </>)}` — BOTH buttons present; Request changes NOT dropped (no behavioral regression).
- ✅ `{task.state === 'plan-review' && task.plan_convergence_active && (<span className="dim">plan-convergence in progress</span>)}` — status span when convergence active.

**No round counter:**
- ✅ No round-number field in API response or UI rendering.

**TypeScript compile:**
- ✅ `npx tsc --noEmit` exits 0 — no type errors.

---

## Tests — #1182

**Bash ALLOW-class (scenarios 1–4):**
- ✅ S1: guard rejects (ok=false) when plan_review_role set + plan:agreed absent; msg contains em-dash, `plan-convergence in progress`, and `plan:agreed`.
- ✅ S2: guard permits (ok=true) in manual mode (no role, empty role, plan:agreed present — all three sub-cases).
- ✅ S3: `plan_convergence_active=true` when plan_review_role + plan-review state + no plan:agreed; field explicitly present.
- ✅ S4: `plan_convergence_active=false` when no role, when non-plan-review state; field present even when false.

**Vitest UI (scenarios 5–6):**
- ✅ S5: asserts BOTH Approve plan AND Request changes absent when `plan_convergence_active=true`; span present.
- ✅ S6: asserts BOTH buttons present when `plan_convergence_active=false`; span absent.

**S1b em-dash literal:**
- ✅ Reference implementation uses literal U+2014 in `"plan-convergence in progress — approve blocked until plan:agreed"`.
