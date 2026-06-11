# crewboss — reliability-zero-trust for coding agents (spec v0, DRAFT)

> **NAME: crewboss** — locked. A reliability persona (a "foreman": runs the board +
> sign-off), not from the guardrails/security cluster. The name is free (no active project);
> the username handle `github.com/crewboss` is taken by a dormant account → we'll take the
> org variant at the repo step (see spinout-plan). **Tagline (draft):** "crewboss — a gated tech-lead
> for your coding agents: runs the board, signs off only on proof, never fakes 'done'."
> **STATUS: DRAFT** — working draft, we iterate.
> **LANG:** the draft is in Russian for iteration; the public release will be in English
> (audience: English-speaking Claude Code teams).
> **Origin:** the design converged during a discussion on top of
> [`PROMPT_roles.md`](./PROMPT_roles.md) and the [OSS research](./PROMPT_roles-oss-research.md).

---

## 0. What this is (in one paragraph)

A pattern (+ a thin Claude-Code reference) that turns the role profile of a coding
agent into **deterministic gates** that hold the boundary not on "we asked the agent
to be good," but on the physics of the configuration. The thesis: **the entire job of an
autonomous tech-lead can be gated by TWO mechanisms + one layer that is honestly NOT
gated — and we say so plainly.** The novelty is not in the mechanisms (they are borrowed),
but in their integration and in the intellectual honesty about what is enforced and what
is not.

---

## 1. Threat model — reliability, NOT security (this is the positioning)

Two different "zero-trusts" that people constantly conflate:

- **Security-zero-trust** — untrusted *INPUT*: prompt injection, external data,
  a malicious agent, token leakage. Well-trodden: dual-LLM, CaMeL, capability-sandbox,
  guardrails. **OUT of scope for this spec.**
- **Reliability-zero-trust** — untrusted *BEHAVIOR* of the agent: it is not malicious, but
  **lazy / over-eager / lies "done" / reads a question as a command / scales on
  a guess**. **THIS is our scope.**

The practical consequence that simplifies everything: since the agent is not an adversary,
we don't need security-grade mechanisms (token isolation, sandbox). **Weaker but sufficient
and fully native** ones are enough — because we are defending against honest
over-eagerness, not against circumvention.

---

## 2. Core idea: you can gate ACTIONS, not JUDGMENT

You cannot hard-gate judgment ("don't read a question as a command" — that's RLHF, not
a permission rule). You can only gate actions and claims. So we split the
profile into **three layers by WHAT holds each one**:

| Layer | What it holds | Enforcement class | Mechanism |
|---|---|---|---|
| **1. Escalation actions** | spawning agents, merge, push to a shared branch, board authorship, batch of issues | **HARD** | identity + tool-allowlist (nail 1) |
| **2. Completion claims** | false "done"/"exhausted", close while incomplete, merge of an unapproved PR | **HARD** | completion-gate on a deterministic proof (nail 2) |
| **3. Disposition / judgment** | question ≠ command, self-praise, "appearing productive," routing classification | **honestly SOFT** | prose in the system prompt; NOT enforced, and we don't pretend |

---

## 3. Roles = launch-time identity (nail 1)

A role is NOT granted by default / by reading config / by inference. It is a
**deterministic choice at launch** (vendor-neutral: "launch-time identity";
Claude Code: `--agent <role>`). A role cannot be changed by a chat phrase — this removes
the "phrase vs identity" conflict (A2 in the original profile): "tech-lead not invoked" = simply
**default identity** (the tool isn't there), not a "deny."

| Role | Activation | Legit tools | Escalation (physically unavailable) |
|---|---|---|---|
| **dev-assistant** (default) | no prefix | Read/Edit/Write; commit+push of its own `fix/` branch; `gh pr create` | board grooming, spawn, merge |
| **Executor** | `--agent executor` | same + `git branch task/<id>`, push of its own task branch, worktree | push to a shared branch, merge, spawn, work outside its own issue |
| **Task-helper** | `--agent task-helper` | Read; `gh issue view/edit/comment`, label | code-edit (no Edit/Write); git-mutation — by mandate, not by hook |
| **Tech-lead** | `--agent tech-lead` | Read; `gh issue create/edit/comment`, labels, milestone, sub-issue; `gh pr view/diff`; `gh pr merge` (nail 2). **Under Arch-2 it does NOT spawn** — executors are launched by the launcher; the tech-lead decomposes (phase-plan) + reviews/merges | the same actions WITHOUT an explicit role invocation |
| **boss** | `--agent boss` (conversational) | Bash → only `gh issue create/comment/edit` (charters) + read-only board | merge, push, spawn, code-read/edit — **code-blind + exec-blind** |
| **analyst** | `--agent analyst` | Read/Bash (read-only investigation) + `gh issue comment` (findings digest) | code-edit, merge, spawn — **read-only, a delegation target** |

**The discriminator between legit work and a failure-mode is the single one: was there an explicit role invocation.**
Identity encodes it deterministically.

### 3.1 Two planes (boundary = task)
- **Conversational (sync, chat):** `dev-assistant` ("do this right now") and `boss`
  ("let's decide WHAT to do → charter"). A human thinks with the AI; the board isn't chewed on.
- **Execution (async, board = I/O):** `tech-lead`, `executor`, `analyst`, `task-helper`
  (executors are launched by the **launcher**, not the tech-lead — Arch-2; the analyst is
  outside the launcher loop, a target for ad-hoc delegation). Task-driven: launch →
  chew the board → no task = stop. "Launch it and go to sleep."

The boundary between planes is the **task/issue**. The gates are the **price** of
unattended autonomy: they are what makes "leaving it to row without supervision"
trustworthy. `boss` cannot become `tech-lead` — it has no execution tools
(tool-absence is recursive: each level = only its own + the right to pass downward).

### 3.2 Plan-approval loop (boss ↔ tech-lead)
The flow of a large goal: `boss` sets a **GOAL** (charter) → `tech-lead` produces a **phase-plan**
(decomposition into a parent + `- [ ] #N` sub-issues + rationale, status `plan-review`) →
`boss` **approves** (flip `approved`) → `tech-lead` does the **execution phase**.
- **Enforce (Arch-2):** until a charter is `approved`, its leaf sub-issues are NOT launchable →
  the launcher does not launch executors (predicate `launchable.sh`; NOT a spawn-gate — there is no spawn).
  The SECOND gate (approving the plan before start) paired with the completion-gate afterward (§5.1).
- **Roles:** boss = WHAT + approve; tech-lead = HOW (decompose) + review/merge (executed by the launcher's executors).
- **Approver:** boss (AI) on everything + a human ONLY on the large/irreversible (a tight trigger).
- **Honest ceiling:** AI-approval = correlated blind spots (AI judging AI) → it raises
  the FLOOR (crude under-scoping), not the CEILING. The ceiling is a rubric/diversity-lens in the boss's review +
  a human on the large. **STATUS: plan-approval BUILT** (a "charter approved" clause in the launcher's predicate, a green test); the scope-completion Stop-gate — NOT built.

---

## 4. The two nails (mechanisms)

### Nail 1 — identity + tool-allowlist
No tool in the role's set → the action is **physically unavailable** (not "the agent decided
not to do it"). Claude-Code reference:
- **role = `--agent <name>`** — a top-level session under the agent's identity;
- **tool-allowlist in the agent file (`tools:`)** — the only local layer that
  **holds even against `bypassPermissions`**: no tool in the set → the model doesn't
  see it and won't call it (verified on v2.1.161);
- **the command level — a central PreToolUse hook that branches on `agent_type`**
  (an stdin field, carrying the `--agent` name): "this role can `gh pr merge`, that one cannot." The hook is
  deterministic: `canon()` collapses **within-model** variants to a literal before matching
  (quotes `gh pr "merge"`, `command`/`/path/gh`, global flags `gh -R o/r pr merge`, REST
  `gh api …/pulls/N/merge`). What slips through is only **intentional evasion** (`gh${IFS}pr…`, `$VAR`,
  `eval`, alias) — adversarial, out of model (§1: "not against circumvention"). This is a **friction-gate against
  honest over-eagerness**, NOT enforcement against evasion;
- evaluation order `hooks → deny → mode → ask → allow`;
- **HONEST CEILING:** the settings `deny` AND the hook-deny are **bypassed** by `bypassPermissions` /
  `--dangerously-skip-permissions` — this is a human escape-hatch, and the agent will **not** turn it
  on itself. Verb-matching canonicalizes within-model variants, but is **defeatable by intentional
  evasion** (`${IFS}`/`$VAR`/`eval`/alias — adversarial, out of model, §1), and `gh pr merge --admin`
  punches through branch protection → the merge anchor needs **require-admins**. Firmly-against-bypass are only tool-absence
  (`tools:`) and server-side GitHub branch protection (§5.2). The settings `deny` = defense-in-depth,
  not a guarantee.

### Nail 2 — completion-gate on a deterministic proof
A PreToolUse hook on a **specific action** knocks it back until a
**deterministic** proof is presented. Not a self-report, **not an LLM judge** (the correlation of
the judge's and the generator's errors makes that an illusion of verification). Claude-Code reference: a PreToolUse hook,
`exit 2` / `permissionDecision: "deny"` cancels the call before the mode check. A command-hook
(deterministic), NOT a prompt/agent hook (that one calls the model — that's no longer a nail).

---

## 5. Proof contract (the crux of layer 2)

**Anchor principle: the proof = the objective state of GitHub at the CURRENT HEAD, never
an artifact the agent can edit** (`- [x]` checklists, labels, its own words).

The recursive chain:

| Action | Role | Proof (deterministic) |
|---|---|---|
| declare "PR ready" | Executor | verification-gate green: required checks on the head SHA == passing (see §5.2) |
| `gh pr merge` | Tech-lead | approval by a **non-author** (`reviewDecision == APPROVED`) **+** green on the head SHA (see §5.2) |
| `gh issue close` | Tech-lead | see §5.1 — the single checkpoint (explicit close; keyword auto-close forbidden) |

### 5.1 Closing an issue — the single checkpoint

**The close path is only an explicit `gh issue close` (agent). Keyword auto-close
(`Closes #N` → server-side close on merge into the default branch) is FORBIDDEN:** it bypasses
the PreToolUse hook and does not fire on a non-default base. One controlled entry point.

PreToolUse hook on `gh issue close #N`:
1. **human-owned** (`type:human-*`: human-test / -decision / -setup …) → **DENY** (a human closes it).
2. **there are open children / unchecked `- [ ] #M`** → **DENY** (decomposition not complete).
3. **a leaf with code** → **ALLOW** iff #N closes/links a **merged PR**
   (gated-ness is guaranteed: a merge is only possible through the merge-gate).
4. **a parent, all children closed** → **ALLOW**.
5. **an analytical deliverable of the tech-lead** (`type:tech-lead`/`analysis`/`research`, no PR) →
   **ALLOW only with a digest proof** (the comment marker `crewboss-digest`). **SOFT:** it proves
   that a digest was presented, NOT that the analysis is correct (consistent with the "digest-proof" matrix).
6. otherwise → **DENY** (no proof).

> Refined and **verified against real issues** (live gh): rule-1 catches any
> `type:human-*` label; rule-5 (the digest proxy) was added for tech-lead analytics without a PR.
> The live run caught a label-detection bug (jq `-e` on the last value in the stream) — fixed.

Sub-cases:
- *One PR → many issues* (`Closes #12, #13`): fine — both inherit the gated-ness of
  the merged PR, the *scope* was signed by the reviewer. No separate mechanism needed.
- *Partial work*: we do NOT gate — we **design it away with decomposition.** A leaf is
  not closed halfway: a fully completed sub-issue is closed by its gated PR;
  the parent closes deterministically (rule 4). The synergy of decomposition and layer 2.
- *Honest remainder (layer 3):* "does the PR fully close the leaf" is judgment; it is borne by
  the **reviewer's approval** (sees the diff + the `Closes` list) + a soft norm in the system prompt ("don't
  hang `Closes` on a partial PR; don't close a parent from one child's PR"). The ceiling
  = the reviewer's good faith; "done" is not provable mathematically.

### 5.2 Source of truth for "green" and freshness

**Truth = required CI status checks on the PR head SHA; we anchor the merge-gate in GitHub branch protection.**
- *CI, not a local run:* CI runs in GitHub's infrastructure, not on the agent's machine → the agent cannot
  fake it (a local run it can skip / substitute the command / run on a dirty
  tree). Server-side truth is our security-vs-reliability watershed.
- *Branch protection = the real nail:* "require approvals + require status checks +
  require up-to-date + **dismiss stale approvals**." Then `gh pr merge` physically cannot
  merge a non-conforming PR (GitHub knocks it back server-side); the PreToolUse hook is a local
  mirror (an earlier/clearer error), not the sole support.
- *Freshness (anti-stale):* everything is bound to the **head SHA** (`headRefOid`), not to "the PR in general"
  → an old green on a previous commit doesn't count; "dismiss stale approvals" removes the
  approval on a new commit → the "approved → pushed more code → merged" scenario is closed.
- *Fallback without CI:* the hook runs the repo's verification command against a **clean checkout
  of the exact head SHA** (not a dirty working tree). Weaker (local) — we mark it honestly.
- *Anti-tamper:* the definition of the verification command / the list of required checks live in the repo →
  to weaken the gate = to change code = to go through a gated merge with an approval.
  You can't weaken it silently.
- *Honest ceiling:* the strength of the gate = which checks are marked **required**. "Green" = "required
  passed on this SHA," not "the code is correct."

**Anti-self-approve:** the approver must be a non-author/human (branch protection +
required review). Otherwise self-approve = the same false-done at the merge level.

**Happy path vs the nail (important):** "the tech-lead creates an approval task and merges upon
receipt" is *behavior* (soft, in the system prompt). The nail is the fact that the merge
is knocked back WITHOUT an approval signal, **whether the agent went the nice way or tried to cut a corner.**
The nail is on the action, not in the instruction — that's the whole difference.

**Honest ceiling (don't paper over):** green CI proves "the declared checks passed on
this commit," NOT "the work is correct/complete." A lazy agent will write green-but-empty
tests. We shift the trust boundary from "the agent's word" to "the objective gate of the repo" —
a big step, but the gate's ceiling = the quality of the tests. "A Stop hook reduces false-done" is
**a hypothesis from the literature, not measured** on our version; we hold it as a hypothesis-to-test.

---

## 6. Routing human-decision (layer 3 + backstop)

The router fires at a **fork** in the course of an autonomous run and **after the analyst's
report**. The buckets:
- *technical + reversible + within competence + I can justify it* → **I decide myself**
  (a justification + "reversible, contest it and we'll replay"). The boundary is bold: I can decide and
  roll back → I am **obliged** to do it myself, not to escalate;
- *product / irreversible / expensive / values-trade-off* → **human-decision** (issue:
  options + recommendation + "why specifically you");
- *the report is incomplete* → another analyst task; *ready for the build* → a dev/agent task.

**Honestly:** the classification itself "into which bucket" is judgment, **layer 3, NOT gated**
(a judge-hook would err the same way as the agent). Deterministic only:
1. **a backstop through the absence of capability** — the truly dangerous/irreversible
   (push to master, drop, billing change, an unapproved merge) is **absent from
   the allowlist of any role**. Bad routing cannot trigger a bad action — the agent is
   **structurally** forced to go to the human, not because it is wise;
2. **emission** of a human-decision issue — an observable `gh` call.

The brand formula: **"we don't enforce that the agent routes wisely; we enforce that
the actions it could route badly are unavailable to it."**

---

## 7. Acceptance matrix (in identity terms)

| Context | Action | Expectation | Class / mechanism |
|---|---|---|---|
| Executor | push of its own `task/` branch | allow (silently) | nail 1 (in allowlist) |
| Executor | merge / spawn a subagent | unavailable | nail 1 (merge = tech-lead-only; no Agent tool) |
| Executor | push to a shared branch | deny | **branch protection** (server-side); the push hook does NOT gate — the role has Bash |
| Executor | declare "PR ready" without a green gate | deny | nail 2 (green on HEAD) |
| dev-assistant | Edit+commit+push `fix/` | allow (silently) | nail 1 |
| dev-assistant | board grooming / spawn | unavailable | nail 1 |
| Task-helper | `gh issue edit/comment` | allow (silently) | nail 1 |
| Task-helper | code / git push | unavailable | nail 1 |
| Tech-lead | `gh issue create` ×N, milestone, sub-issue | allow (silently) | nail 1 |
| Tech-lead | decomposition into sub-issues (phase-plan) | allow (silently) | nail 1; **executors are launched by the launcher, not the tech-lead** (Arch-2) |
| Tech-lead | `gh pr merge` of an approved+green PR | allow | nail 2 (non-author approval + green) |
| Tech-lead | `gh pr merge` of an unapproved PR | deny | nail 2 |
| Tech-lead | `gh issue close` (code issue) | allow iff closed by a merged PR | nail 2 (chain) |
| Tech-lead | `gh issue close` (no-code) | the agent doesn't close | outside nail 2 (human) |
| default identity | any tech-lead action | unavailable | nail 1 (role not invoked = the tool isn't there) |
| at a fork | classify a decision | — | **soft (layer 3)** + backstop |
| any mode | dangerous/irreversible | unavailable | nail 1 (nobody has it) |

---

## 8. What this spec EXPLICITLY does NOT do (brand section — do not cut)

- **Does not fix disposition.** Question ≠ command, self-praise, "appearing productive" —
  layer 3, soft, treated by training, not by a rule. We write "we try," not "enforced."
- **Does not gate routing judgment.** Only the actions beneath it.
- **Does not make the gate impenetrable.** The ceiling of the completion-gate = the quality of the tests; green ≠ correct.
- **Does not hold against `bypassPermissions`.** Hooks and the settings `deny` are bypassed by a human's
  `--dangerously-skip-permissions`; against it, only tool-absence (`tools:`) and
  GitHub branch protection stand. The agent will not enter this mode itself — a human can, and then
  the local gates are off. We say so plainly.
- **Does not protect against injection / a malicious agent / token leakage** — that's
  security-zero-trust, a different project (see Threat model).
- **Does not claim a measured effect** where there is only a hypothesis from the literature.

---

## 9. Reference implementation — scope v0

**Shipping (a thin reference):**
- **5 agent files** (`--agent`): Executor / Task-helper / Tech-lead / **boss** (code-blind+exec-blind) / **analyst** (read-only) + **dev-assistant = default** (no `--agent`, no file); the tool-allowlists;
- PreToolUse gates: `gh pr merge` (approval+green), `gh issue close` (closed-by-a-merged-PR),
  "PR ready" (green on HEAD);
- **the launcher** (`reference/launcher/`): the launchable predicate + the loop (poll→claim→worktree→`--agent executor`→review/blocked + retry-cap) — IT launches the executors (Arch-2), not the tech-lead;
- a demo on a sandbox GitHub repo where you can see the **block** of an unapproved merge and the **block**
  of a close without a closing PR (+ an asciinema/video recording, so adoption doesn't require a run).

**Specified, but NOT coded in v0:**
- gh-aw-style token-split (a read-only agent + a separate write-job) — an **optional
  security-grade upgrade**, not needed for reliability;
- triage/routing logic — prose in the system prompt;
- multi-level spawn / agent-teams (the most vendor-fragile surface — behind a flag);
- **the scope-completion Stop-gate** — designed, NOT built (plan-approval — BUILT: the launcher predicate, §3.2).

---

## 10. Prior art — what we borrow (all MIT/docs; the integration is ours)

- **Claude Code / Agent SDK** (docs) — nail 1 in full (order, bare-name deny,
  deny-non-overridable, dontAsk) + PreToolUse exit-2 for nail 2.
- **github/gh-aw** — safe-outputs as a reference for board operations; token-split as
  an optional security upgrade.
- **ComposioHQ/agent-orchestrator** — the `green CI AND approved` boolean as a model for
  a deterministic merge-gate.
- **Claude Code agent-teams** — `TaskCompleted`/`TeammateIdle` exit-2 as a deterministic completion slot.
- **liberzon/claude-hooks** — decomposition of compound-bash (closes the `git status && rm -rf /` hole).

---

## 11. Open questions / to verify

1. ✅ CONFIRMED (live, CC v2.1.162): the local PreToolUse hook fires
   deterministically in a live `--agent` session (`gh issue create` under dev-assistant
   was intercepted by `crewboss BLOCK` before execution, not bypassed by the model's
   "authorization") — the capability effect is reproducible **without** Actions/token-split. What remains is the happy-path
   mutational merge with a real approval (workstream H).
2. Empirical false-done on the proof chain vs an LLM critic — no data, only the mechanism.
3. ✅ RESOLVED (see §5.1): the explicit `gh issue close` = the single checkpoint, keyword auto-close
   forbidden; the 5-rule hook; "partial" is removed by decomposition. The remaining tail:
   pin down the exact API field for "the merged PR that closes #N" (`gh issue view --json
   closedByPullRequestsReferences` / timeline) before impl.
4. ✅ RESOLVED (see §5.2): truth = required checks on the head SHA + branch protection as the
   server-side anchor; stale is closed by binding to the SHA + dismiss-stale-approvals; no-CI →
   the clean-checkout fallback. The remaining tail: fine-tune the branch-protection recipe at impl time.
5. The project's name/narrative (deferred).
