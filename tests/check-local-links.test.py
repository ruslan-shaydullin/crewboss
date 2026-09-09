#!/usr/bin/env python3
"""Regression tests for the supported-guide local Markdown link checker."""

import contextlib
import io
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import check


def main():
    with tempfile.TemporaryDirectory(prefix="crewboss-links-") as temp:
        fixture_root = Path(temp)

        guide = fixture_root / "README.md"
        existing = fixture_root / "existing.md"

        existing.write_text(
            "# Existing\n",
            encoding="utf-8",
        )

        guide.write_text(
            """# Link fixture

[Existing](existing.md)
[Missing](missing.md)
[External](https://example.com/never-fetch-this)
""",
            encoding="utf-8",
        )

        original_root = check.ROOT
        check.ROOT = fixture_root

        try:
            output = io.StringIO()

            try:
                with contextlib.redirect_stdout(output):
                    check.check_local_links(("README.md",))
            except RuntimeError as error:
                message = str(error)

                assert "README.md" in message, message
                assert "missing.md" in message, message

                print(
                    "ok   missing local target reports source and target"
                )
            else:
                raise AssertionError(
                    "checker unexpectedly passed a fixture "
                    "with a missing target"
                )

            # External URLs must be ignored. The checker performs
            # filesystem-only validation and does not fetch URLs.
            assert "example.com" not in output.getvalue()

        finally:
            check.ROOT = original_root

    print("ok   external URLs are ignored without network access")
    print("=== SUMMARY: 2 passed, 0 failed ===")


if __name__ == "__main__":
    main()