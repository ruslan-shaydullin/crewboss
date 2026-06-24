# Security Review: admin merge flow & CB_INTEGRATOR gate (charter #625, issue #638)

**Status:** APPROVED  
**Date:** 2026-06-24  
**Scope:** `ui/server/crewboss-api.py` do_command merge branch + `reference/runtime/crewboss-integrator.sh` cmd_verify_merged

---

## Questions Reviewed

### 1. Token scope for `--admin` merge

`gh pr merge --admin --merge` requires the GitHub token to carry admin-level repo
permissions. The daemon uses the `gh` CLI's ambient credential (GH_TOKEN / GITHUB_TOKEN),
not `CB_API_TOKEN` (the crewboss HTTP auth token). An under-scoped token causes
`gh pr merge --admin` to return non-zero; the Python code catches this and returns
`{"ok": False, "msg": "pr merge failed: ..."}` — **fail-closed**. No silent success
is possible.

Gap: the required scope (`repo` + repo-admin role) is not spelled out in the spec,
but this is a documentation gap, not a functional hole.

**Verdict: Acceptable — fail-closed on under-scoped tokens.**

---

### 2. Gate bypass via verify-merged

The gate checks `result.returncode != 0`:

- Exit 0 → merge proceeds
- Exit 1 (fail), 2 (infra), 3 (retry/not-confirmed) → all block merge

No environment variable short-circuits `verify-merged` to force exit 0 without
running real checks. `CB_INTEGRATOR` is validated to exist (`os.path.exists`) before
invocation. The N-confirmation anti-poison mechanism (`CB_VERIFY_CONFIRM_N`, default 2)
cannot be used to mask a true RED. The cache key (leaf_sha + target_base_sha) means a
cache hit cannot be manufactured without a real prior pass on those exact SHAs.

**Verdict: Gate cannot be trivially bypassed.**

---

### 3. CB_INTEGRATOR injection

```python
# Resolved once at module load — not per-request:
CB_INTEGRATOR = os.environ.get('CB_INTEGRATOR') or os.path.join(CB_HOME, 'crewboss-integrator.sh')
```

This is a module-level constant. HTTP API callers have zero ability to change it at
runtime. Only the operator who starts the daemon can influence it via the process
environment. The existence guard (`os.path.exists`) does not confine the path to
CB_HOME, but since only a privileged operator (with full server access) can set
CB_INTEGRATOR, this is within the expected trust boundary.

**Verdict: External callers cannot inject CB_INTEGRATOR. Default is repo-local.**

---

### 4. Draft promotion attack surface

Draft PRs in GitHub are already visible to repository members and CI bots (GitHub
Actions run on draft PRs unless workflows filter `github.event.pull_request.draft`).
Since `gh pr merge --admin --merge` bypasses all branch protection including required
reviews, any CI bot interaction between `gh pr ready` and `gh pr merge --admin` cannot
affect the merge outcome. The `verify-merged` gate uses a fresh independent clone from
`--remote` and is unaffected by PR-level CI activity.

**Verdict: Minimal widened attack surface — --admin bypass makes CI bot interactions
irrelevant to merge outcome.**

---

## Summary

| Question | Verdict |
|---|---|
| Token scope | ✅ Fail-closed on under-scoped tokens |
| Gate bypass | ✅ Cannot be trivially bypassed |
| CB_INTEGRATOR injection | ✅ External callers cannot override |
| Draft promotion | ✅ Minimal attack surface widening |

**Overall: APPROVED** — the --admin merge flow and CB_INTEGRATOR gate design are sound
for the described deployment model. No blocking security findings.
