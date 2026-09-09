# Historical runtime snapshot

`cbnet/` preserves a June 2026 operator snapshot used to bring runtime files back
into the repository. It is retained as a compatibility fixture, not an install
source. Scripts here can contain old credentials used for demos, host-specific
paths, and commands that modify external resources.

The current source of truth is
[`reference/runtime-manifest.tsv`](../reference/runtime-manifest.tsv), which maps
canonical runtime files to their locations in the repository.

The snapshot cannot yet be removed: `runtime-manifest.test.sh` checks its inventory
coverage and `deploy-verify.test.sh` uses snapshot scripts. Extract those fixture
dependencies before retiring this directory. Do not deploy or execute the
snapshot as a current setup guide.
