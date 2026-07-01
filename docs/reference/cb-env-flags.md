# CB Environment Flags

Crewboss exposes nine environment variables that operators can set to control runtime
behaviour of the launcher and spawn scripts.  This is the single authoritative reference
for all nine flags; source of truth is
`reference/runtime/crewboss-launcher-gh.sh` (launcher flags) and
`reference/runtime/crewboss-spawn.sh` / `reference/runtime/crewboss-prep-spawn-gh.sh`
(spawn flags).

## Flag Reference

| Flag | Default | Scope | Description |
|------|---------|-------|-------------|
| `CB_MANIFEST` | *(unset)* | launcher | Path to the team manifest directory. When set the launcher locates and sources the manifest library (`manifest.sh`), validates the directory via `manifest_validate`, then exports `CB_MANIFEST` to all child spawns. An invalid or missing library causes an immediate `exit 65` before any issue is claimed. Unset = legacy behaviour (no manifest, byte-for-byte compatible). |
| `CB_CONVERGE_CAP` | `4` | launcher | Maximum number of analyst ↔ reviewer substance-convergence rounds before the launcher stops cycling and opens a human-decision issue. Also used as the fallback default for `CB_FORMAT_CAP` (`${CB_FORMAT_CAP:-${CB_CONVERGE_CAP:-4}}`). |
| `CB_PLAN_CONVERGE_CAP` | `6` (when CB_CONVERGE_CAP is also unset) | launcher | Maximum number of tech-lead planning rounds in the plan-review loop before the launcher stops cycling and opens a human-decision issue. Falls back to `CB_CONVERGE_CAP` when set, otherwise defaults to `6`. Can also be overridden per-charter via a `converge-cap:N` label on the charter issue. |
| `CB_AUTO_PLAN_APPROVE` | `0` | launcher | Set to `1` to automatically approve a charter that reaches `plan-review` state, bypassing the human approval gate. Intended for fully-automated pipelines and CI environments. |
| `CB_AUTO_MERGE` | `0` | launcher | Set to `1` to automatically merge the charter-finale pull request into `main` after CI checks pass, skipping the human merge step. |
| `CB_FS_WORK` | `rw` | spawn | Filesystem access mode for the `/work` bind-mount (repo checkout) inside the nsjail sandbox. Empty or `rw` → read-write bind (`-B`); any other value (e.g. `ro`) → read-only bind (`-R`). Set by `crewboss-prep-spawn-gh.sh` from the manifest role field `fs_work`. Fail-safe: an unrecognised value locks down to read-only rather than silently opening write access. |
| `CB_FS_CBNET` | `rw` | spawn | Filesystem access mode for the `/cbnet` bind-mount (runtime scripts, manifest, run-state) inside the nsjail sandbox. Same semantics and fail-safe behaviour as `CB_FS_WORK`. Set from the manifest role field `fs_cbnet`. |
| `CB_MAX_PARALLEL` | `2` | launcher | Maximum number of executor spawns the launcher will keep running concurrently in `run` mode. Increasing this value raises throughput but also increases API spend rate. |
| `CB_RETRY_CAP` | `2` | launcher | Maximum consecutive failure attempts for a leaf before the launcher routes it to `blocked` state and opens a human-triage label. The retry counter is reset when a leaf is explicitly re-queued by an operator. |

