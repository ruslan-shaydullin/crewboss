#!/usr/bin/env python3
"""Contributor checks. No live launcher, manifest regeneration, or deployments.

The explicit offline selection below covers portable contracts. The complete
engine suite also contains Linux process, timing, and operator-environment tests
and is intentionally not discovered or executed by this runner.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
SHELL_TESTS = (
    "launchable", "manifest-lib", "composition-parse", "board-states",
    "cli-smoke", "role-model-policy", "gate-layer-a", "gate-layer-b",
    "runtime-lint", "runtime-manifest", "doctor-drift",
    "webhook-security", "token-hygiene",
)
SOURCE_TESTS = (
    ("tests/1220-cli-approve-guard.test.sh", "CB_1220_MODE", "bash"),
    ("tests/969-api-pagination.test.py", "CB_969_MODE", sys.executable),
    ("tests/1131-build-state-nonlist.test.py", "CB_1131_MODE", sys.executable),
    ("tests/690-tests-plan-convergence-guard.test.py", "CB_690_MODE", sys.executable),
)
SUPPORTED_GUIDES = (
    "README.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "reference/README.md",
    "ui/README.md",
    "docs/install.md",
    "docs/demo.md",
    "docs/linux-validation.md",
)


def require(*commands):
    missing = [command for command in commands if not shutil.which(command)]
    if missing:
        raise RuntimeError("Missing prerequisites: " + ", ".join(missing))


def run_fixture(command, env):
    # Some contracts start a loopback HTTP server. Keep every fixture in its own
    # process group so an interruption/timeout also stops background children.
    process = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True)
    try:
        return process.wait(timeout=120)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise


def syntax():
    require("bash", "git")
    version = subprocess.check_output(
        ["bash", "-c", 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'],
        text=True,
    )
    if tuple(map(int, version.split("."))) < (5, 0):
        raise RuntimeError(
            f"Bash 5+ is required to parse the runtime (found {version}). "
            "On macOS, put a modern Bash on PATH or run in Linux."
        )
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode().split("\0")
    counts = {"shell": 0, "Python": 0}
    failures = []
    for name in sorted(set(names)):
        path = ROOT / name
        if not path.is_file() or not (
            name.startswith(("reference/", "proto/", "ui/", "tests/", "scripts/", ".claude/hooks/"))
            or name == "crewboss-doctor.sh"
        ):
            continue
        if path.suffix == ".sh" or (
            path.parent == ROOT / "reference/bin"
            and path.read_bytes().startswith(b"#!/usr/bin/env bash")
        ):
            counts["shell"] += 1
            result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True)
            if result.returncode:
                failures.append(result.stderr.strip())
        elif path.suffix == ".py":
            counts["Python"] += 1
            try:
                # Compile in memory so verification does not create __pycache__.
                compile(path.read_bytes(), name, "exec")
            except SyntaxError as error:
                failures.append(f"{name}: {error}")
    if not all(counts.values()):
        raise RuntimeError("Source inventory is empty; run from a complete Git checkout.")
    if failures:
        raise RuntimeError("\n".join(failures))
    print(f"Syntax passed: {counts['shell']} shell and {counts['Python']} Python files.")


def offline():
    require("bash", "git", "jq", "node", "sha256sum", "sort")
    if subprocess.run(["sort", "-z"], input=b"", capture_output=True).returncode:
        raise RuntimeError("The runtime manifest check requires sort with -z support (GNU coreutils).")
    checks = [
        (f"reference/tests/{name}.test.sh", "bash", {}) for name in SHELL_TESTS
    ] + [(path, runner, {mode: "source"}) for path, mode, runner in SOURCE_TESTS]
    for path in (
        "reference/tests/api-startup.test.py",
        "reference/tests/runtime-portability.test.py",
        "reference/tests/launcher-honesty.test.py",
        "reference/tests/runtime-io-lint.test.py",
        "tests/test_api_auth.py", "tests/test_api_launch.py",
        "tests/test_release_package.py",
    ):
        checks.append((path, sys.executable, {}))
    checks.append(("tests/994-search-abort.test.mjs", "node", {}))
    missing = [path for path, _, _ in checks if not (ROOT / path).is_file()]
    if missing:
        raise RuntimeError("Required tests are missing: " + ", ".join(missing))
    failures = []
    with tempfile.TemporaryDirectory(prefix="crewboss-check-") as workspace:
        # Fixture tests must not read the contributor's Git credentials or runtime
        # settings. Individual tests provide their own gh/agent stubs where needed.
        env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CB_", "CREWBOSS_", "CHARTER_", "GH_", "GITHUB_", "GIT_"))
            and not key.endswith("_OVERRIDE")
            and key not in (
                "BASH_ENV", "ENV", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY",
            )
        }
        env.update(
            HOME=workspace,
            XDG_CONFIG_HOME=str(Path(workspace) / "config"),
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_TERMINAL_PROMPT="0",
            PYTHONDONTWRITEBYTECODE="1",
        )
        for path, runner, extra_env in checks:
            print(f"=== {path}", flush=True)
            command = [runner, path] if runner != "node" else [runner, "--test", path]
            try:
                code = run_fixture(command, {**env, **extra_env})
                if code:
                    failures.append(f"{path} (exit {code})")
            except subprocess.TimeoutExpired:
                failures.append(f"{path} (120-second timeout)")
    if failures:
        raise RuntimeError("Failed offline checks:\n" + "\n".join(failures))
    print(f"Offline checks passed: {len(checks)} test files.")

def check_local_links(guides=SUPPORTED_GUIDES):
    """Check repository-relative Markdown links in supported contributor guides."""
    link_pattern = re.compile(
        r"\[[^\]]*\]\(([^)\s]+)(?:\s+['\"][^'\"]*['\"])?\)"
    )

    failures = []

    for guide in guides:
        source = ROOT / guide

        if not source.is_file():
            failures.append(f"{guide}: supported guide is missing")
            continue

        text = source.read_text(encoding="utf-8")

        for match in link_pattern.finditer(text):
            target = match.group(1).strip()
            parsed = urlsplit(target)

            # External URLs and other schemes are not local files.
            if parsed.scheme or parsed.netloc:
                continue

            # Fragment-only links stay within the current document.
            # Heading anchors are intentionally not validated.
            if not parsed.path:
                continue

            local_target = source.parent / unquote(parsed.path)

            try:
                local_target.resolve().relative_to(ROOT.resolve())
            except ValueError:
                failures.append(
                    f"{guide}: local link escapes repository: {target}"
                )
                continue

            if not local_target.exists():
                failures.append(
                    f"{guide}: missing local link target: {parsed.path}"
                )

    if failures:
        raise RuntimeError("\n".join(failures))

    print(f"Local Markdown links passed: {len(guides)} supported guides.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("syntax", "offline", "links"))
    args = parser.parse_args()
    try:
        {"syntax": syntax, "offline": offline, "links": check_local_links}[args.check]()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
