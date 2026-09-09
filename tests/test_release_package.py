#!/usr/bin/env python3
"""Tests for scripts/package-release.py and scripts/install-runtime.sh.

Builds a tiny synthetic checkout in a temporary directory (never the real
working tree), packages it, and drives the real installer via subprocess.
Stdlib unittest only:  python3 -m unittest tests.test_release_package -v
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PACKAGER_PATH = REPO_ROOT / "scripts" / "package-release.py"
INSTALLER_PATH = REPO_ROOT / "scripts" / "install-runtime.sh"


def _load_packager():
    spec = importlib.util.spec_from_file_location("package_release", PACKAGER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


pkg = _load_packager()

VERSION = "0.1.0-alpha.1"
PREFIX = f"crewboss-{VERSION}"

# Synthetic runtime sources: every basename the packager requires, plus the
# launcher allow-list entries.  Contents are stubs; only hashes matter.
RUNTIME_SOURCES = {
    "ui/server/crewboss_http.py": "# HTTP helper fixture\n",
    "ui/server/crewboss_launch.py": "# launcher helper fixture\n",
    "reference/runtime/launcher-board.sh": "#!/usr/bin/env bash\n# board helper\n",
    "reference/runtime/reviewer-verdict.py": "# reviewer fixture\n",
    "reference/runtime/run-charter.sh": "#!/usr/bin/env bash\n# entrypoint fixture\n",
    "reference/launcher/manifest.sh": "#!/usr/bin/env bash\n# manifest helper\n",
    "reference/runtime/run-env.sh": "#!/usr/bin/env bash\necho stub run-env\n",
    "reference/runtime/start-api.sh": "#!/usr/bin/env bash\necho stub start-api\n",
    "reference/runtime/crewboss-doctor.sh": "#!/usr/bin/env bash\necho stub doctor\n",
    "reference/runtime/crewboss-spawn.sh": "#!/usr/bin/env bash\necho stub spawn\n",
    "reference/runtime/crewboss-launcher-gh.sh": "#!/usr/bin/env bash\necho stub launcher\n",
    "reference/runtime/board-gh.sh": "#!/usr/bin/env bash\necho stub board\n",
    "reference/runtime/gh-shim.sh": "#!/usr/bin/env bash\nexec gh \"$@\"\n",
    "reference/runtime/proxy.py": "#!/usr/bin/env python3\nprint('stub proxy')\n",
    "reference/runtime/bridge.py": "#!/usr/bin/env python3\nprint('stub bridge')\n",
    "reference/runtime/redact.pl": "#!/usr/bin/env perl\nprint 'stub';\n",
    "reference/runtime/claude.kafel": "POLICY stub { ALLOW { read, write } }\n",
    "reference/runtime/nsjail-limits.cfg": "rlimit_as_type: HARD\nrlimit_fsize_type: HARD\n",
    "ui/server/crewboss-api.py": "#!/usr/bin/env python3\nprint('stub api')\n",
    "reference/launcher/launchable.sh": "#!/usr/bin/env bash\necho stub launchable\n",
    "reference/launcher/labels-setup.sh": "#!/usr/bin/env bash\necho stub labels\n",
}

SYSTEMD_SOURCES = {
    "reference/runtime/crewboss-api.service": "[Service]\nUser=crewboss\n",
    "reference/runtime/crewboss-launcher.service": "[Service]\nUser=crewboss\n",
    "reference/runtime/crewboss-loop-keepalive.service": "[Service]\nType=oneshot\n",
    "reference/runtime/crewboss-loop-keepalive.timer": "[Timer]\nOnCalendar=minutely\n",
    "reference/runtime/crewboss-loop-keepalive-killmode.conf": "[Service]\nKillMode=process\n",
    "reference/runtime/render-units.py": "#!/usr/bin/env python3\nprint('stub render')\n",
    "reference/runtime/deploy-units.sh": "#!/usr/bin/env bash\necho stub deploy-units\n",
}

OTHER_SOURCES = {
    "VERSION": VERSION + "\n",
    "README.md": "# fixture readme\n",
    "LICENSE": "fixture license\n",
    "CHANGELOG.md": "# fixture changelog\n",
    "docs/install.md": "# fixture install docs\n",
    "reference/runtime/api.env.example": "CB_REPO=\nCB_API_TOKEN=\n",
    "reference/.claude/settings.json": "{\"permissions\": {\"allow\": [\"Read\"]}}\n",
    "reference/.claude/hooks/crewboss-gate.sh": "#!/usr/bin/env bash\nexit 0\n",
    "reference/.claude/agents/executor.md": "# executor fixture role\n",
    "team-example/org.json": "{\"nodes\": []}\n",
    "team-example/rubric.json": "{\"rubric\": []}\n",
    "team-example/manifest-doctor.sh": "#!/usr/bin/env bash\nexit 0\n",
    "team-example/roles/python-dev.md": "# python-dev fixture role\n",
    "ui/app/dist/index.html": "<!doctype html><title>fixture ui</title>\n",
    "ui/app/dist/assets/app.js": "console.log('fixture');\n",
    # Host build artifact: must be silently excluded from the bundle.
    "ui/app/dist/.vite/manifest.json": "{}\n",
}


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_fixture(root: Path) -> None:
    for rel, content in {**RUNTIME_SOURCES, **SYSTEMD_SOURCES, **OTHER_SOURCES}.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    scripts = root / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    shutil.copy(INSTALLER_PATH, scripts / "install-runtime.sh")

    rows = ["# fixture runtime manifest", "# repo_path\tsha256\tstatus\tpurpose"]
    for rel in sorted(RUNTIME_SOURCES):
        rows.append(f"{rel}\t{_sha(RUNTIME_SOURCES[rel])}\tcanonical\tfixture row")
    # systemd rows with allowed origins: must be routed to systemd/, not runtime/.
    for rel in ("reference/runtime/crewboss-api.service",
                "reference/runtime/render-units.py"):
        rows.append(f"{rel}\t{_sha(SYSTEMD_SOURCES[rel])}\tcanonical\tfixture unit row")
    # Rows the packager must ignore WITHOUT requiring the files to exist:
    rows.append(f"proto/net/old-bridge.py\t{'1' * 64}\tcanonical\tprototype origin")
    rows.append(f"reference/runtime/board-gh.sh\t{'2' * 64}\tlegacy\tretired prototype")
    rows.append(f"reference/runtime/retired-tool.sh\t{'3' * 64}\tlegacy\tretired runtime")
    rows.append(f"ui/server/run-api-test2.sh\t{'4' * 64}\tcanonical\tnon-.py ui/server row")
    manifest = root / "reference/runtime-manifest.tsv"
    manifest.write_text("\n".join(rows) + "\n", encoding="utf-8")


def read_archive(archive: Path):
    with tarfile.open(archive, "r:gz") as tar:
        members = {m.name: m for m in tar.getmembers()}
        data = {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}
    return members, data


def extract_archive(archive: Path, dest: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        try:
            tar.extractall(dest, filter="data")
        except TypeError:  # Python < 3.12 without the filter keyword
            tar.extractall(dest)


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cb-release-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "repo"
        self.out = self.tmp / "out"
        write_fixture(self.root)

    def build(self, **kwargs):
        kwargs.setdefault("output_dir", self.out)
        kwargs.setdefault("source_date_epoch", 0)
        return pkg.build_release(self.root, **kwargs)

    @property
    def manifest_path(self) -> Path:
        return self.root / "reference/runtime-manifest.tsv"


class PackageBuildTests(FixtureCase):
    def test_build_produces_versioned_archive_and_sidecar(self):
        result = self.build()
        self.assertEqual(result.version, VERSION)
        self.assertEqual(result.archive, self.out.resolve() / f"{PREFIX}.tar.gz")
        self.assertTrue(result.archive.is_file())
        digest = hashlib.sha256(result.archive.read_bytes()).hexdigest()
        self.assertEqual(result.sha256, digest)
        self.assertEqual(result.checksums.read_text(),
                         f"{digest}  {PREFIX}.tar.gz\n")

    def test_default_output_is_outside_the_source_tree(self):
        result = pkg.build_release(self.root, source_date_epoch=0)
        self.addCleanup(shutil.rmtree, result.archive.parent, True)
        self.assertNotIn(str(self.root), str(result.archive))
        self.assertTrue(result.archive.is_file())

    def test_build_is_deterministic(self):
        first = self.build(output_dir=self.tmp / "out1")
        second = self.build(output_dir=self.tmp / "out2")
        self.assertEqual(first.archive.read_bytes(), second.archive.read_bytes())
        self.assertEqual(first.sha256, second.sha256)

    def test_source_date_epoch_stamps_members(self):
        result = self.build(source_date_epoch=123456789)
        members, _ = read_archive(result.archive)
        self.assertTrue(all(m.mtime == 123456789 for m in members.values()))

    def test_bundle_layout_ownership_and_modes(self):
        result = self.build()
        members, data = read_archive(result.archive)

        for name, member in members.items():
            self.assertTrue(name == PREFIX or name.startswith(PREFIX + "/"), name)
            self.assertEqual((member.uid, member.gid), (0, 0), name)
            self.assertEqual((member.uname, member.gname), ("root", "root"), name)
            self.assertEqual(member.mtime, 0, name)

        for expected in (
            f"{PREFIX}/README.md", f"{PREFIX}/LICENSE", f"{PREFIX}/CHANGELOG.md",
            f"{PREFIX}/VERSION", f"{PREFIX}/SHA256SUMS",
            f"{PREFIX}/install-runtime.sh", f"{PREFIX}/crewboss.env.example",
            f"{PREFIX}/docs/install.md",
            f"{PREFIX}/runtime/runtime-manifest.tsv",
            f"{PREFIX}/runtime/gh-shim.sh", f"{PREFIX}/runtime/crewboss-api.py",
            f"{PREFIX}/runtime/launchable.sh", f"{PREFIX}/runtime/labels-setup.sh",
            f"{PREFIX}/team/org.json", f"{PREFIX}/team/rubric.json",
            f"{PREFIX}/team/manifest-doctor.sh",
            f"{PREFIX}/team/roles/python-dev.md",
            f"{PREFIX}/gov/.claude/settings.json",
            f"{PREFIX}/gov/.claude/hooks/crewboss-gate.sh",
            f"{PREFIX}/gov/.claude/agents/executor.md",
            f"{PREFIX}/gov/.claude/agents/python-dev.md",
            f"{PREFIX}/systemd/crewboss-api.service",
            f"{PREFIX}/systemd/crewboss-loop-keepalive.timer",
            f"{PREFIX}/systemd/render-units.py", f"{PREFIX}/systemd/deploy-units.sh",
            f"{PREFIX}/ui/index.html", f"{PREFIX}/ui/assets/app.js",
        ):
            self.assertIn(expected, members)

        self.assertEqual(data[f"{PREFIX}/VERSION"].decode(), VERSION + "\n")
        self.assertEqual(members[f"{PREFIX}/install-runtime.sh"].mode, 0o755)
        self.assertEqual(members[f"{PREFIX}/runtime/run-env.sh"].mode, 0o755)
        self.assertEqual(members[f"{PREFIX}/runtime/redact.pl"].mode, 0o755)
        self.assertEqual(members[f"{PREFIX}/systemd/render-units.py"].mode, 0o755)
        self.assertEqual(members[f"{PREFIX}/gov/.claude/hooks/crewboss-gate.sh"].mode,
                         0o755)
        self.assertEqual(members[f"{PREFIX}/runtime/claude.kafel"].mode, 0o644)
        self.assertEqual(members[f"{PREFIX}/systemd/crewboss-api.service"].mode, 0o644)

        # systemd artifacts must not appear in the flat runtime, and prototype /
        # host / dependency files must not be embedded at all.
        self.assertNotIn(f"{PREFIX}/runtime/crewboss-api.service", members)
        self.assertNotIn(f"{PREFIX}/runtime/render-units.py", members)
        self.assertNotIn(f"{PREFIX}/ui/.vite/manifest.json", members)
        for name in members:
            self.assertNotIn("proto/", name)
            self.assertNotIn("node_modules", name)
            self.assertNotIn(".git/", name)

    def test_shipped_manifest_covers_exactly_the_flat_runtime(self):
        result = self.build()
        members, data = read_archive(result.archive)
        manifest = data[f"{PREFIX}/runtime/runtime-manifest.tsv"].decode()
        rows = [line.split("\t") for line in manifest.splitlines()
                if line and not line.startswith("#")]

        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(row[2], "canonical", row)
            self.assertFalse(row[0].startswith("proto/"), row)

        row_basenames = {row[0].rsplit("/", 1)[-1] for row in rows}
        flat = {name.rsplit("/", 1)[-1]
                for name, member in members.items()
                if member.isfile() and name.startswith(f"{PREFIX}/runtime/")}
        self.assertEqual(row_basenames, flat - {"runtime-manifest.tsv"})

        # The manifest hashes must match the shipped file contents (what the
        # doctor drift check will verify on the installed box).
        for row in rows:
            basename = row[0].rsplit("/", 1)[-1]
            shipped = data[f"{PREFIX}/runtime/{basename}"]
            self.assertEqual(hashlib.sha256(shipped).hexdigest(), row[1], basename)

    def test_internal_checksums_cover_every_file(self):
        result = self.build()
        _, data = read_archive(result.archive)
        listed = {}
        for line in data[f"{PREFIX}/SHA256SUMS"].decode().splitlines():
            listed[line[66:]] = line[:64]
        files = {name[len(PREFIX) + 1:]: blob for name, blob in data.items()
                 if name != f"{PREFIX}/SHA256SUMS"}
        self.assertEqual(set(listed), set(files))
        for rel, digest in listed.items():
            self.assertEqual(hashlib.sha256(files[rel]).hexdigest(), digest, rel)

    def test_main_cli_succeeds(self):
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()) as captured:
            rc = pkg.main(["--repo-root", str(self.root), "--output", str(self.out)])
        self.assertEqual(rc, 0)
        self.assertIn(f"{PREFIX}.tar.gz", captured.getvalue())

    def test_tampered_runtime_file_fails_with_hash_mismatch(self):
        target = self.root / "reference/runtime/proxy.py"
        target.write_text("print('tampered')\n", encoding="utf-8")
        with self.assertRaisesRegex(pkg.PackageError, "hash mismatch"):
            self.build()

    def test_missing_manifest_file_fails(self):
        base = self.manifest_path.read_text()
        self.manifest_path.write_text(
            base + f"reference/runtime/ghost.sh\t{'a' * 64}\tcanonical\tabsent\n")
        with self.assertRaisesRegex(pkg.PackageError, "missing from checkout"):
            self.build()

    def test_duplicate_deployment_basename_fails(self):
        content = "#!/usr/bin/env python3\nprint('other proxy')\n"
        (self.root / "ui/server/proxy.py").write_text(content, encoding="utf-8")
        base = self.manifest_path.read_text()
        self.manifest_path.write_text(
            base + f"ui/server/proxy.py\t{_sha(content)}\tcanonical\tdup basename\n")
        with self.assertRaisesRegex(pkg.PackageError, "duplicate deployment basename"):
            self.build()

    def test_unsafe_manifest_paths_fail(self):
        base = self.manifest_path.read_text()
        for bad in ("/etc/passwd", "reference/runtime/../../evil.sh",
                    "reference/runtime/./x.sh"):
            with self.subTest(path=bad):
                self.manifest_path.write_text(
                    base + f"{bad}\t{'a' * 64}\tcanonical\tbad row\n")
                with self.assertRaisesRegex(pkg.PackageError, "unsafe path"):
                    self.build()

    def test_invalid_versions_fail(self):
        for bad in ("1.0", "v1.0.0", "0.1.0+build.1", "0.1.0-alpha_1", "01.0.0", ""):
            with self.subTest(version=bad):
                (self.root / "VERSION").write_text(bad + "\n", encoding="utf-8")
                with self.assertRaisesRegex(pkg.PackageError, "invalid version"):
                    self.build()

    def test_missing_built_ui_fails(self):
        (self.root / "ui/app/dist/index.html").unlink()
        with self.assertRaisesRegex(pkg.PackageError, "built UI missing"):
            self.build()

    def test_missing_required_runtime_row_fails(self):
        base = [line for line in self.manifest_path.read_text().splitlines()
                if "gh-shim.sh" not in line]
        self.manifest_path.write_text("\n".join(base) + "\n")
        with self.assertRaisesRegex(pkg.PackageError, "gh-shim.sh"):
            self.build()


class InstallerTests(FixtureCase):
    def setUp(self):
        super().setUp()
        result = self.build()
        extract_dir = self.tmp / "extracted"
        extract_archive(result.archive, extract_dir)
        self.bundle = extract_dir / PREFIX
        self.dest = self.tmp / "cbnet"  # intentionally not created

    def run_installer(self, *args):
        return subprocess.run(
            ["bash", str(self.bundle / "install-runtime.sh"), *args],
            capture_output=True, text=True)

    def test_install_produces_expected_tree(self):
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertEqual(proc.returncode, 0, proc.stderr)

        # Flat runtime at the prefix root (no runtime/ subdirectory).
        self.assertFalse((self.dest / "runtime").exists())
        for basename in ("run-env.sh", "start-api.sh", "crewboss-doctor.sh",
                         "crewboss-api.py", "gh-shim.sh", "claude.kafel",
                         "runtime-manifest.tsv"):
            self.assertTrue((self.dest / basename).is_file(), basename)
        for executable in ("run-env.sh", "crewboss-api.py", "redact.pl"):
            self.assertTrue(os.access(self.dest / executable, os.X_OK), executable)
        self.assertFalse(os.access(self.dest / "claude.kafel", os.X_OK))

        for rel in ("team/org.json", "team/rubric.json", "team/roles/python-dev.md",
                    "gov/.claude/settings.json", "gov/.claude/agents/executor.md",
                    "gov/.claude/agents/python-dev.md",
                    "systemd/crewboss-api.service",
                    "systemd/crewboss-loop-keepalive-killmode.conf",
                    "ui/index.html", "ui/assets/app.js"):
            self.assertTrue((self.dest / rel).is_file(), rel)
        for executable in ("gov/.claude/hooks/crewboss-gate.sh",
                           "systemd/render-units.py"):
            self.assertTrue(os.access(self.dest / executable, os.X_OK), executable)

        self.assertTrue((self.dest / "run").is_dir())
        self.assertTrue((self.dest / "gh").is_symlink())
        self.assertEqual(os.readlink(self.dest / "gh"), "gh-shim.sh")

        # Doctor parity: every canonical row of the installed manifest names an
        # installed file whose sha256 matches — a clean drift check.
        manifest = (self.dest / "runtime-manifest.tsv").read_text().splitlines()
        rows = [line.split("\t") for line in manifest
                if line and not line.startswith("#")]
        self.assertTrue(rows)
        for row in rows:
            installed = self.dest / row[0].rsplit("/", 1)[-1]
            self.assertTrue(installed.is_file(), row[0])
            self.assertEqual(hashlib.sha256(installed.read_bytes()).hexdigest(),
                             row[1], row[0])

        self.assertIn("crewboss-doctor.sh --preflight", proc.stdout)
        self.assertIn("start-api.sh --foreground", proc.stdout)

    def test_refuses_existing_nonempty_prefix(self):
        self.dest.mkdir()
        keep = self.dest / "live-file.txt"
        keep.write_text("do not touch\n", encoding="utf-8")
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("non-empty", proc.stderr)
        self.assertEqual(os.listdir(self.dest), ["live-file.txt"])
        self.assertEqual(keep.read_text(), "do not touch\n")

    def test_unlisted_bundle_file_is_rejected_before_install(self):
        (self.bundle / "runtime/unlisted.sh").write_text("unverified content")
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_symlink_bundle_file_is_rejected_before_install(self):
        (self.bundle / "runtime/proxy.py").unlink()
        (self.bundle / "runtime/proxy.py").symlink_to(self.root / "reference/runtime/proxy.py")
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_prefix_is_required_and_never_inferred(self):
        proc = self.run_installer()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("--prefix", proc.stderr)
        self.assertFalse(self.dest.exists())

    def test_relative_prefix_is_rejected(self):
        proc = self.run_installer("--prefix", "relative/cbnet")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("absolute", proc.stderr)

    def test_tampered_bundle_fails_before_any_mutation(self):
        (self.bundle / "runtime/proxy.py").write_text("tampered\n", encoding="utf-8")
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("proxy.py", proc.stderr)
        self.assertFalse(self.dest.exists(),
                         "prefix must not be created when verification fails")

    def test_missing_checksum_entry_fails(self):
        (self.bundle / "runtime/board-gh.sh").unlink()
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_bundle_without_ui_is_refused(self):
        shutil.rmtree(self.bundle / "ui")
        proc = self.run_installer("--prefix", str(self.dest))
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("ui", proc.stderr)
        self.assertFalse(self.dest.exists())

    def test_help_documents_prefix(self):
        proc = self.run_installer("--help")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--prefix", proc.stdout)
        self.assertIn("never overwritten", proc.stdout)


if __name__ == "__main__":
    unittest.main()
