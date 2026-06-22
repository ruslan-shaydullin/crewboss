# Review: Charter #305 — Queue visibility & state machine overhaul

**Reviewer leaf:** #419  
**Reviewed PRs:** #415 (leaf-327), #416 (leaf-328 / rework), #417 (leaf-329), #418 (leaf-qa)  
**Verdict:** ✅ APPROVED — all checklist items pass

---

## Checklist results

### Deletion persistence fix (leaf-327 / #415)

- ✅ `postQueue` in `ui/app/src/api.ts` (lines 182-189) checks `response.ok` and throws on
  non-2xx status:
  ```ts
  if (!r.ok) throw new Error('postQueue failed: ' + r.status)
  ```
- ✅ No silent HTTP-error swallowing remains anywhere in the queue save path. The only queue
  POST call is in `handleQueueChange` which wraps the throw in a `try/catch` that correctly
  keeps `dirtyRef.current = true` on failure.

### `dirtyRef` correctness (leaf-327 / #415)

- ✅ `dirtyRef.current = false` is set **only in the success path** of `handleQueueChange`
  (inside `try`, before the `catch` block, at the same time as `setSavedOrder`).
- ✅ A failed POST leaves `dirtyRef.current = true` (set at the top of the handler, and the
  `catch` block also reinforces it), so SSE cannot overwrite unsaved local state.

### `isLoopRunning` derivation (leaf-327 / #415)

- ✅ `isLoopRunning` is computed at the App level as:
  ```ts
  const isLoopRunning = state?.loop?.running ?? false
  ```
  (App.tsx line 141) and passed down as a prop.
- ✅ No component derives `isLoopRunning` from local state — it is always sourced from the
  SSE-fed `state` object.

### `onPendingAdd` prop chain (leaf-329 / #417)

- ✅ `loopRunning: boolean` is threaded through the full chain:
  App → Board → CharterSection / MilestoneGroup → CharterCard
- ✅ `onPendingAdd: (n: number) => void` follows the identical chain.
- ✅ CharterCard calls `onPendingAdd(c.n)` when `loopRunning && !isQueued`.
- ✅ CharterCard calls `onQueueChange([...queueOrder, c.n])` when `!loopRunning && !isQueued`
  (unchanged behaviour path preserved).

### Dirty indicator (leaf-327 / #415)

- ✅ `savedOrder` is updated via `setSavedOrder(newOrder)` **only inside the `try` block**,
  after a successful `await postQueue(newOrder)`. On failure the `catch` is reached without
  updating `savedOrder`.
- ✅ Dirty indicator computed in `QueuePanel` as:
  ```ts
  const isDirty = JSON.stringify(queueOrder) !== JSON.stringify(savedOrder)
  ```
  It is hidden (false) once `savedOrder` matches `queueOrder` after a successful save.
- ✅ It is visible (true) while there are unsaved changes.

### QueuePanel always-visible (leaf-328 / #416)

- ✅ `QueuePanel` is rendered inside `<div className="queue-panel--sticky">` which is a child
  of `.sidebar-col`, outside the `<section className="board">` scrollable column.
- ✅ CSS layout (`styles.css` lines 74-84) uses a grid with `sidebar-col` as a sticky
  right-hand column (`position:sticky; top:18px; max-height:calc(100vh - 36px)`). The
  agents rail gets `overflow-y:auto` so it scrolls independently; the queue panel is
  `flex-shrink:0` at the bottom of the column, always visible. No overlap with the board.

### No regression

- ✅ All existing queue behaviour preserved: the `!loopRunning` path in CharterCard is
  unchanged; QueuePanel move/remove logic is identical.
- ✅ `npm test` coverage: `queue.test.ts` and `charter-sections.test.ts` include tests for
  all new behaviors — `postQueue` error handling, `dirtyRef` state machine, `isLoopRunning`
  derivation, `pendingQueue` state logic, button label derivation, and pending→confirmed flow.
- ✅ No TypeScript errors: all new props (`loopRunning`, `onPendingAdd`, `pendingQueue`,
  `onRemovePending`) are typed in component signatures and correctly threaded.

---

## Summary

All 14 checklist items pass. The implementation is clean, correctly scoped, and well-tested.
The `dirtyRef` state machine correctly prevents SSE from clobbering unsaved local edits.
The QueuePanel layout change is additive and does not regress existing behaviour.

**Verdict: APPROVED.**
