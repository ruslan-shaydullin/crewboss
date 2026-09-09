# Contributing to crewboss

Contributions that make crewboss easier to run, understand, and verify are welcome.
Start with the [project overview](README.md) and [documentation index](docs/README.md).
For security vulnerabilities, follow [SECURITY.md](SECURITY.md).

## Set up a development checkout

Fork the repository, clone your fork, and create a branch for your change. The
default checks run locally without GitHub authentication, a Claude account, or a
deployed crewboss instance.

Use Git, Make, Bash 5.0 or newer, `jq`, and GNU coreutils (`sha256sum` and `sort -z`).
CI uses Python 3.12 and Node.js 22 with npm; use those versions to reproduce its
environment. The API uses the Python standard library; there is no Python package
installation step. The UI has its own locked npm dependencies:

```sh
npm ci --prefix ui/app
make check
```

`make setup` is an alias for the npm dependency installation command.

Dependency installation needs network access. After installation, the default
checks use local fixtures and stubs. See the [CI workflow](.github/workflows/ci.yml)
for the environment used in automated checks.

The complete orchestration runtime targets Linux and uses facilities such as
`flock`, namespaces, nsjail, and systemd. Its launcher requires modern Bash;
macOS's bundled Bash 3.2 cannot run code that uses associative arrays. Use a Linux
environment for changes to process supervision, deployment, or sandboxing.
Running the UI or the default contributor checks does not provision that runtime.

## Find the right source

| Area | Location |
| --- | --- |
| CLI and installation helpers | `reference/bin/`, `reference/install.sh` |
| Role definitions and command gate | `reference/.claude/` |
| GitHub board launcher, integrator, and spawn helpers | `reference/runtime/` |
| API implementation | `ui/server/crewboss-api.py` |
| React dashboard | `ui/app/src/` |
| Team configuration examples | `team-example/` |
| Shell and Python regression tests | `reference/tests/`, `tests/` |

[`reference/runtime-manifest.tsv`](reference/runtime-manifest.tsv) identifies
runtime source files and their recorded hashes. Some canonical files still live
under `proto/`; check the manifest and callers before moving or deleting them.
The older launcher in `reference/launcher/` is also used by the CLI and its tests.

Local runtime state, credentials, installed dependencies, generated UI builds,
and private agent settings belong outside the commit. Use placeholder repository
names and hostnames in examples and redact sensitive data from logs.

## Run checks for your change

`make check` runs the following targets:

| Target | Purpose |
| --- | --- |
| `make check-syntax` | Check source syntax without starting the runtime |
| `make test-offline` | Run the selected shell, Python, and Node regression checks |
| `make test-ui` | Run the dashboard's Vitest suite once |
| `make build-ui` | Build the dashboard |

For UI work, start the development server with:

```sh
npm run dev --prefix ui/app -- --host 127.0.0.1
```

See the [UI guide](ui/README.md) for connecting the dashboard to an API. For an
individual existing test, use its documented invocation or the corresponding
test command in the check runner.

The default suite is a contributor baseline. It does not certify a deployed
launcher, GitHub permissions, branch protection, or sandbox isolation. Some
historical tests exercise a bundled reference implementation by default and
require an explicit source mode to test the shipped implementation. Check the
test header and report which mode you ran.

Live scripts can create repositories, modify issues and pull requests, start
agents, or consume paid sessions. Read each script before running it; use a
disposable repository and a separately configured runtime. The
[live sandbox guide](reference/live/README.md) describes the older launcher demo.
Do not run every `*.sh` file as a blanket test command. Browser tests under
`ui/app/scripts/` may also require Playwright browser downloads or a running API;
they are separate from the default Vitest suite.

When a change affects a file listed as `canonical` in the runtime manifest, run
the relevant behavioral checks, then refresh and review the recorded hashes:

```sh
bash reference/bin/regen-manifest.sh
git diff -- reference/runtime-manifest.tsv
```

This helper requires `sha256sum`. Inspect every changed row; a matching hash
records file contents and does not establish that the implementation is correct.

## Send a focused pull request

For a bug, include a small reproduction, the expected result, the actual result,
and relevant environment versions. For a larger design change, describe the
problem and intended behavior in an issue before investing in a broad rewrite.
English is preferred for new public documentation; existing Russian design
notes remain useful context.

Keep a pull request focused on one problem. Follow the surrounding code style
and `.editorconfig`, update affected documentation, and add a regression test
when behavior changes. Tests should exercise the failure being fixed, including
the rejected path for gates, rather than only checking for a string in source.
Keep unrelated formatting and generated files out of the diff.

In the pull request, explain what changes for a user or operator, include the
commands and outcomes of your checks, and state any relevant checks you could
not run. Do not present fixture results as live verification. Be considerate in
issues and reviews: explain disagreements with reproducible examples and evidence.

## Contributor backlog and installed runtime checks

The [roadmap](docs/roadmap.md) separates small public contributions from the
existing orchestration milestones. Start with a task labeled `good first issue`
or `help wanted`; the local demo needs no provider account.

CI also runs the [installed Linux acceptance test](docs/linux-validation.md) with
real systemd, flock and nsjail. GitHub and provider traffic are local fixtures.
Do not run that system-level fixture on a shared production runtime.

When changing a canonical runtime file, run
`bash reference/bin/regen-manifest.sh` after the relevant behavior tests and review
the manifest diff. Verification checks the committed hashes without regenerating
them. New runtime helpers must be included in the release inventory. When changing
production UI dependencies, update the complete license notices collected by
`scripts/package-release.py`; these are installed with the dashboard.
