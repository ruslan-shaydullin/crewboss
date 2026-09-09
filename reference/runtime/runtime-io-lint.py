#!/usr/bin/env python3
"""Reject shell fallbacks that forge decisions after runtime I/O failure."""
from pathlib import Path
import re
import sys

RULES = {
    "transport-fallback": re.compile(
        r'(?:\bgh\s+(?:issue|pr|api)\b|\b_cb_issue_\w+).*?\|\|\s*(?:echo|printf)\s+[\'\"]?(?:false|true|\[\])'),
    "double-zero": re.compile(r'(?<![\'\"\w])grep\s+-c\s+.*?\|\|\s*echo\s+[\'\"]?0'),
}


def violations(path):
    logical = ""
    start = 0
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if not logical:
            start = number
        logical += line.rstrip().removesuffix("\\") + " "
        if line.rstrip().endswith("\\"):
            continue
        for name, pattern in RULES.items():
            if pattern.search(logical):
                yield f"{path}:{start}: {name}"
        logical = ""


if __name__ == "__main__":
    root = Path(sys.argv[1]) if len(sys.argv) == 2 else None
    if root is None or not root.is_dir():
        print("usage: runtime-io-lint.py RUNTIME_DIRECTORY", file=sys.stderr)
        sys.exit(2)
    findings = [finding for path in sorted(root.rglob("*.sh")) for finding in violations(path)]
    if findings:
        print("\n".join(findings))
    sys.exit(bool(findings))
