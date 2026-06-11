# crewboss

**Reliability-zero-trust governance for autonomous coding agents.**

Coding agents (Claude Code, the Agent SDK, …) aren't malicious. They're *unreliable*: lazy,
over-eager, and prone to saying "done" when it isn't. They read a question as a command, merge a
PR nobody approved, close a half-finished issue, spawn work you never asked for. crewboss is a
thin, native pattern + reference config that makes an agent's **dangerous actions** and
**completion claims** answer to deterministic proof — not to the agent's own word.

## The wedge: two kinds of zero-trust

- **Security** zero-trust distrusts the *input* (prompt injection, untrusted data). Well-explored:
  dual-LLM, CaMeL, capability sandboxes.
- **Reliability** zero-trust distrusts the *agent's own behavior* (it's lazy/dishonest, not
  hostile). Much less explored. **This is crewboss's angle.**

## Two nails + one honest layer

crewboss enforces exactly what can be enforced deterministically, and is honest about what can't.

1. **Nail 1 — role = launch-time identity.** A role is a deterministic launch choice
   (`claude --agent <role>`), not something the agent infers and not something a chat phrase
   grants. Each role's `tools:` allowlist removes whole capabilities: an executor has no `Agent`
   tool, so it *cannot* spawn sub-agents — the action is physically absent, not "the agent chose
   not to." **Tool-absence is the one local control that holds even under
   `--dangerously-skip-permissions`.**

2. **Nail 2 — completion-gate on deterministic proof.** The finalizing verbs (`gh pr merge`,
   `gh issue close`, `gh pr ready`) are gated by a central `PreToolUse` hook that checks an
   *artifact*, not a self-report: a merge needs a non-author approval **+** green checks on the
   head SHA; a close needs a merged PR, a completed parent, or an analysis digest. Saying "it's
   done" doesn't get a half-finished thing past the gate.

3. **Layer 3 — disposition (honestly NOT enforced).** "A question isn't a command," self-praise,
   looking busy — these are soft and can't be fixed by rules, only by training. crewboss does
   **not** pretend to enforce them. Claiming a layer is enforced when it isn't is the exact
   dishonesty this project exists to catch.

## Honest ceiling (read this)

- **Bypass-proof:** only tool-absence (`tools:`) and server-side GitHub branch protection survive
  a determined human escape-hatch (`--dangerously-skip-permissions`, which the agent can't enable
  for itself).
- **Friction, not a wall:** the `PreToolUse` hook is deterministic against the literal command and
  folds *in-model* obfuscations (quoting, global flags, `gh api` for merge/close), but a determined
  `${IFS}`/`eval`/alias **evasion is out of the reliability threat-model by design** — that's
  adversarial behavior, and the model is "lazy, not hostile." The hook catches the careless agent,
  not an attacker.
- We say this plainly instead of overclaiming. (Two un-correlated red-team sweeps of crewboss
  caught *its own authors* overclaiming — and a live run found a real config gap. See the spec.)

## Roles

| Launch | Role | Tools (absence = hard boundary) |
|---|---|---|
| `claude` (no flag) | **dev-assistant** (default) | Read/Edit/Write/Bash; no Agent |
| `claude --agent executor` | **executor** | Read/Edit/Write/Bash; **no Agent** — takes one issue → PR, stops at review |
| `claude --agent task-helper` | **task-helper** | Read/Bash; **no Edit/Write** — board only |
| `claude --agent tech-lead` | **tech-lead** | Read/Bash — decomposes work + reviews/merges *approved* PRs |
| `claude --agent boss` | **boss** | Bash only; code-blind + exec-blind — authors charters for the tech-lead |
| `claude --agent analyst` | **analyst** | Read/Bash (read-only) — investigates, posts a findings digest |

Two planes: a **conversational** plane (dev-assistant, boss — you chat with them) and an
**execution** plane (tech-lead, executor, analyst, task-helper — board-driven, "launch and sleep").
The boundary is the task/issue. The execution plane never spawns sub-agents in-session; a launcher
runs executors as separate processes (Arch-2). See [board-orchestration.md](board-orchestration.md).

## Quick start

One command (via the `crewboss` CLI in [`reference/bin/`](reference/bin/crewboss)):

```bash
crewboss init      # writes .claude/ (agents + hook + settings.json with permissions.allow) + labels
crewboss doctor    # pre-flight: deps, auth, config, branch protection — tells you what to fix
```

Or by hand — `init` just does this:

```bash
# from your repo root
cp -r reference/.claude .                     # agents + hook
chmod +x .claude/hooks/crewboss-gate.sh
```
Add the `PreToolUse` hook **and** a tool allowlist to `.claude/settings.json` (the allowlist lets
an unattended `claude -p` run without stalling on approval prompts; the hook still gates the
dangerous subset — it runs first, and an exit-2 deny beats any allow rule):

```json
{
  "permissions": { "allow": ["Bash", "Edit", "Write", "Read"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/crewboss-gate.sh" } ] }
    ]
  }
}
```
Then launch a role **explicitly** (`claude --agent tech-lead`). For unattended/launcher runs, turn
on GitHub **branch protection** (require approvals + required checks) — that is the server-side
anchor that holds even where the local hook can be bypassed. Full config, the launcher, the test
suite, and a live-sandbox script are in [reference/](reference/).

## Status

Reference v0, **live-verified**: role-gating + completion-gates (harness 46/46 + 20/20), the
launcher (integration 10/10, data-loss fix proven), and an end-to-end live run — launcher → real
`claude --agent executor` → real PR → review, with the merge-gate denying an unapproved merge on a
real PR (including an obfuscated `--admin` attempt). Not yet covered: the approved→merge happy path
(needs a second reviewer) and a public/paid branch-protection demo.

## Docs

- **Spec** — [agent-reliability-gating-spec-v0.en.md](docs/agent-reliability-gating-spec-v0.en.md):
  the full design (three layers, roles, the proof contract §5, the honest ceiling).
- **Reference** — [reference/](reference/): drop-in Claude Code config (agents, hook, launcher,
  tests, live-sandbox script).
- **Board orchestration** — [board-orchestration.md](board-orchestration.md): the Arch-2 launcher +
  label state-machine.
- **Status** — [STATUS.md](STATUS.md).

> crewboss is incubating; the public repository and an English-first README will be split out at
> release. This document is the front-page draft.
