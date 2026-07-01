# Review: Charter #485 — Stuck-charter red highlight + hover tooltip in cockpit queue

**Reviewer leaf:** #1214  
**Reviewed leaves:** #1212 (backend: `_compute_stuck` helper), #1213 (frontend: `api.ts` type + `App.tsx` QueuePanel + `styles.css` stuck rule)  
**Verdict:** ✅ APPROVED — all 7 backend scenarios and both frontend smoke tests pass; TypeScript build clean

---

## Machine acceptance checks

| # | Command | Result |
|---|---------|--------|
| 1 | `python3 -m pytest tests/test_stuck_reason.py` | 7/7 PASS |
| 2 | `cd ui/app && npm run build` | 0 type errors; `dist/main.js` 215.1 kb |
| 3 | `cd ui/app && npm run test -- --run src/stuck.test.tsx` | 2/2 PASS |

---

## Backend review (leaf #1212 — `ui/server/crewboss-api.py`)

### B-1  Signal detection order

**File:** `ui/server/crewboss-api.py`, lines 395–440

The helper `_compute_stuck(n, labels, issues, plan_convergence_active, finale_pr)` applies exactly the 5-signal spec order: HD issue → `status:blocked` label → no leaf children → finale PR → plan convergence.  First match wins; `return` is immediate.

- ✅ Signal 1 (`type:human-decision` issue open + body references `#n`) fires before label check.
- ✅ Signal 2 (`status:blocked` label, including suffixed variants like `status:blocked: upstream`) propagates the suffix as part of the reason string.
- ✅ Signal 3 (no leaf children) identifies leaves by *absence* of `type:charter` or `type:milestone` labels on items whose body references `#n` — no `.get("kind")` field used (correct for raw GitHub REST dicts).
- ✅ Signal 4 (finale PR): `gh pr view <pr> --json isDraft,state` is monkeypatched in tests; draft *or* non-MERGED PR fires stuck.
- ✅ Signal 5 (plan convergence) fires only when the four earlier signals are all absent.
- ✅ Happy-path returns `{"is_stuck": False, "reason": None}`.

### B-2  Closed HD issue must NOT fire

The guard is:

```python
and it.get("state", "").lower() != "closed"
```

- ✅ A closed `type:human-decision` issue, even with a matching body, does not set `is_stuck`.

### B-3  Suffix on `status:blocked` label

```python
suffix = lname[len("status:blocked"):].strip(": ")
reason = f"blocked: {suffix}" if suffix else "blocked"
```

- ✅ Plain `status:blocked` → `"blocked"`.
- ✅ `status:blocked: upstream` → `"blocked: upstream"` (startswith covers all variants).

### B-4  Leaf-child detection uses raw REST label dicts

```python
leaf_children = [it for it in issues
    if (f"#{n}" in (it.get("body") or ""))
    and not any(l.get("name") in ("type:charter", "type:milestone")
        for l in it.get("labels", []))]
```

- ✅ Checks `l.get("name")`, not `l.get("kind")` — matches the GitHub REST shape.
- ✅ Body reference requirement (`f"#{n}" in body`) prevents false positives from unrelated issues.

### B-5  `crewboss_api.py` shim

`ui/server/crewboss_api.py` re-exports `_compute_stuck` so that `from crewboss_api import _compute_stuck` in the test file works:

```python
_compute_stuck = _mod._compute_stuck
```

- ✅ Import path `sys.path.insert(0, "ui/server")` in the test matches.

---

## Backend test scenarios (7/7 PASS)

| # | Scenario | Expected | Actual |
|---|----------|----------|--------|
| 1 | Open `type:human-decision` issue references `#42` | `is_stuck=True`, reason=`"human decision pending"` | ✅ PASS |
| 2 | CLOSED `type:human-decision` issue (same body) | `is_stuck=False`, reason=`None` | ✅ PASS |
| 3 | Charter label `status:blocked`, no issues | `is_stuck=True`, reason starts with `"blocked"` | ✅ PASS |
| 4 | issues list has only `type:charter` + `type:milestone` items | `is_stuck=True`, reason=`"no leaves"` | ✅ PASS |
| 5 | finale_pr set, monkeypatched `subprocess.run` → `isDraft=False, state=OPEN` | `is_stuck=True`, reason=`"finale PR awaiting merge"` | ✅ PASS |
| 6 | `plan_convergence_active=True`, leaf present, no finale_pr | `is_stuck=True`, reason=`"plan cap: awaiting review"` | ✅ PASS |
| 7 | Clean charter: leaf present, no signals | `is_stuck=False`, reason=`None` | ✅ PASS |

---

## Frontend review (leaf #1213)

### F-1  `api.ts` type extension

**File:** `ui/app/src/api.ts`, line 17

```typescript
stuck?: { is_stuck: boolean; reason: string | null } | null  // #485 - stuck charter highlight
```

- ✅ Optional (`?`) and nullable (`| null`) — safe for boards that predate the backend change.
- ✅ `reason: string | null` matches what `_compute_stuck` returns on both paths.

### F-2  `App.tsx` QueuePanel rendering

**File:** `ui/app/src/App.tsx`, line 1040

```tsx
<li key={n}
    className={`queue-panel__item${charter?.stuck?.is_stuck ? " queue-panel__item--stuck" : ""}`}
    title={charter?.stuck?.is_stuck ? (charter.stuck?.reason ?? undefined) : undefined}
    data-testid="queue-item" data-n={n}
    onClick={() => onOpen(n)}>
```

- ✅ Optional-chaining (`?.`) guards all access to `charter.stuck`.
- ✅ CSS class applied only when `is_stuck` is truthy.
- ✅ `title` set to the reason string (or `undefined` when not stuck, which omits the attribute).
- ✅ `null` reason coerced to `undefined` via `?? undefined` — prevents a literal `"null"` tooltip.
- ✅ No change to `data-testid` or `data-n` — other consumers unaffected.

### F-3  `styles.css` stuck rule

**File:** `ui/app/src/styles.css`, line 457

```css
.queue-panel__item--stuck { background: rgba(220, 38, 38, 0.15); border-left: 3px solid #dc2626 }
```

- ✅ Low-opacity red background (`rgba(220,38,38,0.15)`) — visible but not garish.
- ✅ Solid 3 px left border in the same red (`#dc2626`) — standard danger/blocked convention.
- ✅ Selector is additive (does not override `queue-panel__item` base styles for non-stuck items).

---

## Frontend smoke tests (2/2 PASS)

| # | Test | Expected | Actual |
|---|------|----------|--------|
| 1 | `stuck: {is_stuck: true, reason: 'human decision pending'}` | Class `queue-panel__item--stuck` present; `title` = `"human decision pending"` | ✅ PASS |
| 2 | `stuck: {is_stuck: false, reason: null}` | Class `queue-panel__item--stuck` absent; no `title` attribute | ✅ PASS |

---

## TypeScript build

`cd ui/app && npm run build` — **0 type errors**, output `dist/main.js` 215.1 kb.

The `stuck` field is correctly typed; all optional-chain call sites compile without errors.

---

## False-positive risk assessment

| Risk | Mitigation |
|------|-----------|
| HD issue for a *different* charter triggers stuck | Body check `f"#{n}" in body` scopes to the specific charter number |
| Closed HD issue fires stuck | Explicit `state != "closed"` guard |
| Charter with only milestone children fires stuck | Milestone items (`type:milestone`) are excluded from leaf count alongside charters |
| `reason: null` rendered as tooltip `"null"` | `?? undefined` coercion in JSX drops the attribute |
| Old boards without `stuck` field break rendering | `stuck?: ... \| null` — optional + nullable; all access behind `?.` |

---

## Summary

Both implementation leaves (#1212 and #1213) are correct and complete.  All 11 checklist items are satisfied.  The 5-signal detection order is faithfully implemented with proper first-match semantics, no false-positive risks identified.  The TypeScript build is clean and the frontend renders correctly for both stuck and non-stuck items.

**All acceptance criteria met.  PR approved.**
