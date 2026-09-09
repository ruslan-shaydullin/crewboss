# Retired deployment snapshot

The June 2026 deployment copies have been removed after extracting the two test
dependencies into [reference/tests/fixtures/legacy-runtime](../reference/tests/fixtures/legacy-runtime/):
the original filename inventory and one intentionally stale launcher entrypoint.

The manifest coverage and deployment drift tests use these focused fixtures.
Current runtime files live in [reference/runtime](../reference/runtime/); install
from a versioned release, not a historical snapshot. Git history preserves the
original copies for investigation.
