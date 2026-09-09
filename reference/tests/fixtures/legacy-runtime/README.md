# Historical deployment fixture

`inventory.txt` preserves the filename inventory of the 2026-06-11 deployment
snapshot formerly stored in `_box-snapshot/cbnet`. The runtime manifest coverage
test still accounts for each name through a maintained, legacy or excluded entry.

`stale/run-charter.sh` is the original outdated launcher entrypoint. Deployment
verification must identify its checksum drift and the missing integrator. Other
duplicate runtime copies were removed after their callers were migrated to the
canonical source. This fixture is test data, never an installation source.
