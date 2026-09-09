#!/usr/bin/env python3
"""Contract tests for runtime transport/parse fallbacks (#1341)."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

LINT = Path(__file__).resolve().parents[1] / "runtime/runtime-io-lint.py"


class RuntimeIoLintTests(unittest.TestCase):
    def check(self, source):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "runtime.sh"
            path.write_text(source)
            return subprocess.run([sys.executable, str(LINT), root], capture_output=True, text=True)

    def test_gh_failure_cannot_be_boolean_or_empty_array(self):
        for fallback in ('echo false', 'echo "[]"', "printf '[]'"):
            with self.subTest(fallback=fallback):
                result = self.check('value=$(gh issue view 1 --json labels \\\n  | jq .labels || ' + fallback + ')\n')
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('transport-fallback', result.stdout)

    def test_double_zero_count_is_rejected(self):
        result = self.check('count=$(grep -c pattern file || echo 0)\n')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('double-zero', result.stdout)

    def test_explicit_failure_and_comments_are_allowed(self):
        result = self.check('# value=$(gh issue view 1 || echo false)\nvalue=$(gh issue view 1) || return 75\ncount=$(grep -c pattern file); count=${count:-0}\n')
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
