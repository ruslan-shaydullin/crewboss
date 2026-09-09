# crewboss

GitHub-based orchestration and reliability gates for coding agents.

crewboss coordinates work through issues and pull requests. Agents have explicit
roles; a launcher dispatches tasks, and gates check evidence before work moves
through planning, review, and completion. A React dashboard exposes the board,
agent activity, and operator controls through a Python API.

**Status: experimental.** The repository contains an evolving Bash runtime,
Claude Code configuration, a dashboard, and the prototypes behind them. Expect
manual setup and changes to interfaces. The hosted runtime targets Linux; the
local dashboard and contributor checks can run on macOS or Linux with the
prerequisites below.

## How it works

1. **Define work on the board.** A charter describes a goal; child issues describe
   tasks, dependencies, and acceptance criteria.
2. **Launch explicit roles.** Agent configurations define responsibilities and
   tool lists. The launcher runs agents as separate processes and coordinates
   work through GitHub state.
3. **Check selected transitions.** A `PreToolUse` hook gates commands such as
   `gh pr merge`, `gh pr ready`, and `gh issue close` using review, check, and
   completion evidence.
4. **Inspect and intervene.** The CLI and dashboard expose board state; the runtime
   includes approval handling, retries, recovery, and a kill switch.

The [board orchestration design](board-orchestration.md) explains the state machine
and the separation between conversational roles and board-driven execution.

The command hook is a reliability guardrail, not a sandbox for hostile code.
Agents with shell access can act outside it. Use repository permissions and
server-side branch protection for shared branches, and inspect the
[security notes](SECURITY.md) before running agents with real credentials.

## Start with the local checks

You need Git, Bash 4.4+, Python 3, jq, Node.js 22, npm, Make, and GNU coreutils.
See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and platform requirements.
Agent credentials and a cloud server are not required for these checks.

```sh
git clone https://github.com/ruslan-shaydullin/crewboss.git
cd crewboss
make setup
make check
```

The checks include the Layer-A and Layer-B gate harnesses, selected offline
runtime and API contracts, UI tests, and a production build. These cover local
behavior using fixtures and stubs. Live GitHub permissions, Claude Code
integration, and deployment behavior require separate verification. Required
checks must be configured on GitHub: the merge-gate fixtures include a case that
accepts an approved PR with no checks.

To start the dashboard, follow the [local UI guide](ui/README.md). It includes
an empty-board development setup with a local API, before connecting a GitHub
repository or installing an agent runtime.

## Try the role configuration

The reference CLI is checked into the repository; there is no global package to
install. Add its directory to your current shell's PATH:

```sh
export PATH="$PWD/reference/bin:$PATH"
crewboss help
```

With jq installed, run the following **inside a separate Git repository** where
you want to try crewboss:

```sh
crewboss init
crewboss doctor
```

`init` copies the reference roles and hook into `.claude/`, merges the hook and
tool permissions into `.claude/settings.json`, and creates or updates labels
when `gh` is authenticated. It replaces same-named role and hook files, so review
existing configuration and the resulting diff. `doctor` also checks GitHub auth
and branch protection. Running an agent requires your own Claude Code
installation and account.

This CLI uses the legacy reference launcher for `crewboss run`. The current
board runtime is in `reference/runtime/`; it needs a separately provisioned Linux
environment. See the [reference guide](reference/README.md) and
[operator notes](reference/runtime/README.md) before using it.

## Repository map

| Path | Purpose |
| --- | --- |
| [`reference/.claude/`](reference/.claude/) | Distributable roles, hook, and settings |
| [`reference/bin/`](reference/bin/) | CLI and maintenance tools |
| [`reference/runtime/`](reference/runtime/) | Current board runtime and operator scripts |
| [`reference/runtime-manifest.tsv`](reference/runtime-manifest.tsv) | Canonical runtime paths and checksums |
| [`reference/launcher/`](reference/launcher/) | Legacy CLI launcher and shared helpers |
| [`ui/server/crewboss-api.py`](ui/server/crewboss-api.py) | Dashboard state, commands, events, and GitHub webhooks |
| [`ui/app/`](ui/app/) | React dashboard and UI tests; see the [UI guide](ui/README.md) |
| [`team-example/`](team-example/) | Example team manifest, roles, and review rubric |
| [`reference/tests/`](reference/tests/), [`tests/`](tests/) | Runtime and regression tests |
| [`docs/`](docs/README.md) | Design, operations, and historical records |
| [`proto/`](proto/), [`_box-snapshot/`](_box-snapshot/) | Prototypes and compatibility fixtures; some remain runtime/test dependencies |

The root `.claude/` configures development of crewboss itself; it is distinct from
the distributable configuration in `reference/.claude/`.

## Contributing

Bug reports, documentation fixes, and focused pull requests are welcome. Start
with [CONTRIBUTING.md](CONTRIBUTING.md), the
[documentation index](docs/README.md), and the
[code of conduct](CODE_OF_CONDUCT.md). Reports and discussions can be in English
or Russian; new public-facing documentation should be in English.

The original design is available in
[English](docs/agent-reliability-gating-spec-v0.en.md) and
[Russian](docs/agent-reliability-gating-spec-v0.md). Historical status and roadmap
documents record earlier experiments; their test totals and deployment claims
are not current release guarantees.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses. Claude Code
and GitHub are external services; this project does not include access to them.
