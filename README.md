# crewboss

**GitHub-based orchestration and reliability gates for coding agents.**

crewboss explores how to make autonomous development work inspectable: tasks live
in GitHub issues, agents run with explicit roles, and selected merge and completion
actions pass through checks against repository state. The repository includes a
Bash runtime, a Python API, and a React + TypeScript dashboard.

**Status: experimental reference implementation.** The code, design notes, and
test harnesses are public. Setup still requires operator configuration, and the
deployed runtime contains Linux- and systemd-specific components.

## How it works

1. **Define work on the board.** A charter describes a goal; child issues describe
   tasks, dependencies, and acceptance criteria.
2. **Launch explicit roles.** Claude Code agent configurations define responsibilities
   and tool lists. The launcher runs agents as separate processes and coordinates
   work through GitHub state.
3. **Check selected transitions.** A `PreToolUse` hook gates commands such as
   `gh pr merge`, `gh pr ready`, and `gh issue close` using review, check, and
   completion evidence.
4. **Inspect and intervene.** The CLI and dashboard expose board state; the runtime
   includes approval handling, retries, recovery, and a kill switch.

The [board orchestration design](board-orchestration.md) explains the state machine
and the separation between conversational roles and board-driven execution.

## Explore the implementation

| Area | Entry point | What to inspect |
| --- | --- | --- |
| Agent configuration | [`reference/.claude/agents/`](reference/.claude/agents/) | Role responsibilities and declared tool lists |
| Completion gates | [`crewboss-gate.sh`](reference/.claude/hooks/crewboss-gate.sh) | Command matching, role checks, and evidence checks |
| CLI | [`reference/bin/crewboss`](reference/bin/crewboss) | Initialization, diagnostics, board status, and approvals |
| Runtime | [`reference/runtime/`](reference/runtime/) | Board launcher, recovery, deployment scripts, and systemd units |
| API | [`ui/server/crewboss-api.py`](ui/server/crewboss-api.py) | Dashboard state and commands, events, and GitHub webhooks |
| Dashboard | [`ui/app/`](ui/app/) | React + TypeScript application and UI tests |
| Tests | [`reference/tests/`](reference/tests/) | Gate, launcher, recovery, and runtime harnesses |

The CLI's `run` command currently invokes the older launcher in
[`reference/launcher/`](reference/launcher/). The deployed board runtime is kept
separately in `reference/runtime/`; see the [reference guide](reference/README.md)
before choosing a setup.

## Get started

Clone the repository and inspect the CLI commands:

```bash
git clone https://github.com/ruslan-shaydullin/crewboss.git
cd crewboss
bash reference/bin/crewboss help
```

To install the reference configuration into a GitHub-backed working repository,
first make Bash, Git, `jq`, GitHub CLI (`gh`), and Claude Code available. Authenticate
`gh` for the target repository, then run the following from the crewboss checkout,
replacing `/path/to/your/repository` with the target checkout:

```bash
CREWBOSS_CHECKOUT="$(pwd)"
cd /path/to/your/repository
bash "$CREWBOSS_CHECKOUT/reference/bin/crewboss" init
bash "$CREWBOSS_CHECKOUT/reference/bin/crewboss" doctor
```

`init` copies agent definitions and the hook into `.claude/`, merges configuration
into `.claude/settings.json`, and attempts to create workflow labels through `gh`.
It also adds `Bash`, `Edit`, `Write`, and `Read` to the permissions allowlist. Review
the resulting configuration before launching agents. Configure GitHub branch
protection with required reviews and checks for the target workflow.

The [reference guide](reference/README.md), [Russian walkthrough](guide.ru.md),
and [UI guide](ui/README.md) provide more setup context. Some deployment examples
refer to the original development environment and need adaptation.

## Testing and verification

The repository contains shell and Python harnesses plus Vitest and browser-based
UI tests. Two focused gate harnesses can be run from the crewboss checkout with
Bash and `jq` installed:

```bash
bash reference/tests/gate-layer-a.test.sh
bash reference/tests/gate-layer-b.test.sh
```

Verified locally on 9 September 2026: **46 Layer-A cases and 20 Layer-B cases
passed**, with zero failures. The CLI `help` command was also exercised.

The first exercises command and role decisions; the second supplies controlled
`gh` responses for merge, ready, and close scenarios. These harnesses cover local
gate behavior. Live GitHub permissions, Claude Code integration, and deployment
behavior require separate verification.

The current [GitHub Actions workflow](.github/workflows/ci.yml) is a placeholder:
it prints a message and does not execute the test suites. Historical test counts
and live-run notes are recorded in [STATUS.md](STATUS.md); that file is an
incubation snapshot, with outdated visibility and release details.

## Scope and limitations

- The hook handles selected command forms. Shell indirection and deliberate
  evasion are outside its documented reliability model.
- Agent tool lists describe available interfaces. Roles that retain `Bash` need
  additional controls to restrict filesystem, process, or network access.
- GitHub branch protection is a separate control. The merge-gate fixtures include
  a case that accepts an approved PR with no checks, so required checks must be
  configured on GitHub.
- The recorded live validation leaves the approved-merge path with a second
  reviewer and branch protection as an open verification item.
- The reference notes document specific Claude Code versions. Compatibility with
  another version should be checked before unattended use.

## Design and project notes

- [English design specification](docs/agent-reliability-gating-spec-v0.en.md)
- [Russian design specification](docs/agent-reliability-gating-spec-v0.md)
- [Board orchestration](board-orchestration.md)
- [Reference implementation guide](reference/README.md)
- [Historical status and validation notes](STATUS.md)
- [Roadmap](ROADMAP.md)

The repository currently has no `LICENSE` file.
