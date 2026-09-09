# Documentation

Start with the [project README](../README.md) for what crewboss does and how to try
it, or [CONTRIBUTING.md](../CONTRIBUTING.md) to work on the code.

## Guides and source references

| Document | Use it for |
| --- | --- |
| [Reference implementation](../reference/README.md) | CLI, role configuration, and the two launcher paths |
| [UI guide](../ui/README.md) | Dashboard development and API setup |
| [Runtime operator guide](../reference/runtime/README.md) | API deployment and webhook configuration |
| [Runtime manifest](../reference/runtime-manifest.tsv) | Canonical runtime file paths and recorded hashes |
| [Team example](../team-example/) | Organization, role, and review rubric examples |
| [Security policy](../SECURITY.md) | Security boundaries and vulnerability reporting |

## Architecture and design history

These documents explain the project's design and development. Many describe a
particular prototype or deployment, contain historical test counts, or refer to
old issue numbers. They are context for reading the implementation; verify
commands, defaults, and completion claims against the current source and tests.

- [Reliability gating specification — English](agent-reliability-gating-spec-v0.en.md)
  and [Russian original](agent-reliability-gating-spec-v0.md): the original role
  boundaries and completion proof contracts.
- [Board orchestration](../board-orchestration.md): the original issue and label
  workflow and process-based launcher design.
- [End-to-end loop process map](design/loop-process-map.md): the expanded charter,
  leaf delivery, and supervision flows, with source references.
- [Agent configuration map](design/agent-config-map.md): the role capability model
  and its planned enforcement boundaries (Russian).
- [Convergence loop](design/convergence-loop.md): analysis and review feedback
  design (Russian).
- [Environment flag notes](reference/cb-env-flags.md): a historical subset of
  launcher and spawn configuration; consult the scripts for the full set.

## Operational and historical records

- [Live sandbox exercise](../reference/live/README.md): a real GitHub and Claude
  exercise for the legacy launcher; running it can create resources and spend
  agent sessions.
- [Review records](reviews/): evidence and findings from past changes, including
  the former root `.reviews/` directory and standalone review note.
- [Incident notes](incidents/): investigations from previous deployments.
- [Operator reference notes](reference/): deployment and configuration records.
- [Roadmap](../ROADMAP.md) and [status log](../STATUS.md): historical planning and
  progress snapshots.
- [Prototype experiments](../proto/): development experiments alongside some
  files still included in the runtime manifest.

Use generic hostnames, repository names, and credential placeholders when adding
examples. New setup instructions should say which environment they require and
whether commands only inspect state or also create and modify resources.
