# Historical prototypes

This tree preserves the experiments behind the board runtime, sandbox and early
provisioning. It is not the supported installation path. Current installation
uses `scripts/package-release.py` and `scripts/install-runtime.sh`.

The active GitHub board adapter, proxy bridge and redaction filter live in
`reference/runtime/`. Legacy examples and tests remain here where they explain
earlier behavior; some regression tests still exercise them explicitly. Rows
marked `legacy` in the runtime manifest are excluded from installation.

Do not run a historical provision or live-agent script as a setup tutorial. See
[the installation guide](../docs/install.md) and [contributor checks](../CONTRIBUTING.md).
