# Reference implementation

This directory contains the distributable Claude Code configuration, a small
CLI, the board runtime, and regression tests. Start with the
[project README](../README.md) or [contributor guide](../CONTRIBUTING.md).

## Install the role configuration

From your crewboss checkout, add the CLI to the current shell's PATH:

```sh
export PATH="$PWD/reference/bin:$PATH"
crewboss help
```

Then change into a separate Git repository and run `crewboss init`. It copies
`.claude/agents/` and the hook from this directory, merges tool permissions and
hook wiring into the target's `.claude/settings.json`, and ensures labels when
`gh` is authenticated. Existing same-named roles and hook files are overwritten;
review the target's diff before committing. `crewboss doctor` checks dependencies,
configuration, GitHub access, and branch protection.

Launching a role requires your own Claude Code installation and account:

```sh
claude --agent executor
```

Verify the installed CLI's role and hook behavior before an unattended run.
Version numbers and test totals in older design records describe past runs.

## Components

| Path | Responsibility |
| --- | --- |
| `.claude/agents/` | Distributable role definitions and tool lists |
| `.claude/hooks/crewboss-gate.sh` | Command and completion-evidence checks |
| `.claude/settings.json` | Reference hook wiring |
| `bin/crewboss` | `init`, `doctor`, `status`, approval, and role launch commands |
| `launcher/crewboss-launcher.sh` | Legacy foreground launcher used by `crewboss run` |
| `runtime/crewboss-launcher-gh.sh` | Current GitHub board launcher |
| `runtime/` | Integration, spawn, supervision, and deployment helpers |
| `runtime-manifest.tsv` | Canonical runtime inventory and checksums |
| `tests/` | Runtime and regression checks |

The current board runtime is a separate Linux deployment. See the
[operator notes](runtime/README.md). `crewboss init` installs role configuration;
it does not provision a complete hosted runtime.

The manifest distinguishes maintained runtime files from historical prototypes
and separately packaged assets. Snapshot regression data lives in
`tests/fixtures/legacy-runtime/`; the duplicate deployment copies were retired.

## Roles and boundaries

Read each agent file for its complete contract. Common roles include:

- **boss**: turns goals into charters.
- **tech-lead**: plans work and reviews changes through the board.
- **executor**: implements one assigned issue and hands off a pull request.
- **integrator**: assembles changes on the charter branch.
- **analyst** and **test-planner**: produce investigation and test-planning evidence.
- **task-helper**: handles board tasks without editing source.

The launcher starts execution agents as separate processes. Prompt instructions
and tool lists are useful boundaries, but a role with Bash can use shell
capabilities beyond named editor tools. The command hook does not constitute a
hostile-code sandbox; see [SECURITY.md](../SECURITY.md).

The repository-root `.claude/` is crewboss's own development configuration and
can differ from this distributable copy. `install.sh` and `uninstall.sh` are older
local installation helpers; use the documented CLI for a new setup and inspect
any existing configuration before replacing it.

## Checks and design records

Run `make check` from the repository root for the contributor baseline. The
[contributor guide](../CONTRIBUTING.md) explains its scope and the separate live
and process-integration tests.

The [original specification](../docs/agent-reliability-gating-spec-v0.en.md),
[board design](../board-orchestration.md), and
[live sandbox record](live/README.md) document the project's development. The live
sandbox script creates GitHub resources and can spend agent sessions.
