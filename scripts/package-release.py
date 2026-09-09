#!/usr/bin/env python3
"""Build the versioned crewboss open-source release archive.

Produces a deterministic crewboss-<version>.tar.gz (plus a SHA256SUMS sidecar)
from an explicit, manifest-driven file list — never a broad copy of the
working tree.  The bundle layout matches what install-runtime.sh installs and
what crewboss-doctor.sh verifies on a box:

    crewboss-<version>/
        README.md LICENSE CHANGELOG.md VERSION SHA256SUMS
        install-runtime.sh crewboss.env.example
        docs/install.md
        runtime/            flat runtime files + filtered runtime-manifest.tsv
        team/               org.json, rubric.json, roles/*.md
        gov/.claude/        settings.json, hooks/, agents/ (agents ∪ team roles)
        systemd/            unit templates + render-units.py + deploy-units.sh
        ui/                 built dashboard (ui/app/dist)

Runtime files are collected ONLY from canonical rows of
reference/runtime-manifest.tsv whose origin is reference/runtime/*,
ui/server/*.py, or the allow-listed reference/launcher entries.  Prototype
rows (proto/*) and non-canonical rows (legacy, pending-backport) are ignored
and never required.  The shipped runtime/runtime-manifest.tsv contains only
the rows that are actually installed flat, so the doctor drift check
validates exactly the installed files; systemd unit templates are routed to
systemd/ and dropped from the shipped manifest.

Determinism: entries are sorted, uid/gid=0, uname/gname=root, and
mtime=SOURCE_DATE_EPOCH (default 0) for both tar members and the gzip header,
so two builds of the same tree are byte-identical.

Stdlib only.  Version is read from the repository root VERSION file.
"""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import io
import os
import posixpath
import re
import sys
import tarfile
import tempfile
from pathlib import Path

MANIFEST_REL = "reference/runtime-manifest.tsv"
UI_DIST_REL = "ui/app/dist"
ENV_EXAMPLE_REL = "reference/runtime/api.env.example"

VERSION_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MANIFEST_STATUSES = {"canonical", "legacy", "asset", "pending-backport"}

# Origins whose canonical rows become the flat runtime.  Everything else in the
# manifest (proto/* prototypes, ui/app assets, shell tests in ui/server) is
# deliberately ignored: prototypes are being marked legacy and must never be
# required for a release.
RUNTIME_ORIGIN_PREFIX = "reference/runtime/"
UI_SERVER_PREFIX = "ui/server/"
EXTRA_RUNTIME_ORIGINS = {
    "reference/launcher/launchable.sh",
    "reference/launcher/labels-setup.sh",
    "reference/launcher/manifest.sh",
}

# systemd artifacts stay out of the flat runtime (and out of the shipped
# manifest — the doctor would otherwise report them MISSING at CB_HOME root).
# render-units.py resolves templates relative to itself, so the helpers ship
# in the same systemd/ directory as the templates.
SYSTEMD_SUFFIXES = (".service", ".timer", ".conf")
SYSTEMD_HELPERS = ("render-units.py", "deploy-units.sh")
SYSTEMD_TEMPLATES = (
    "crewboss-api.service",
    "crewboss-launcher.service",
    "crewboss-loop-keepalive.service",
    "crewboss-loop-keepalive.timer",
    "crewboss-loop-keepalive-killmode.conf",
)

# Completeness gate: a bundle that cannot pass `crewboss-doctor.sh --preflight`
# or that lacks the entrypoints the installer wires up is not a release.  These
# must be provided by canonical manifest rows from the allowed origins
# (prototype copies do NOT satisfy this — migrate them to reference/runtime/).
REQUIRED_RUNTIME_BASENAMES = frozenset({
    "claude.kafel", "proxy.py", "bridge.py", "redact.pl",
    "crewboss-spawn.sh", "crewboss-launcher-gh.sh", "board-gh.sh",
    "crewboss-doctor.sh", "run-env.sh", "start-api.sh",
    "crewboss-api.py", "gh-shim.sh", "crewboss_http.py", "crewboss_launch.py",
    "launcher-board.sh", "reviewer-verdict.py", "run-charter.sh",
    "launchable.sh", "labels-setup.sh", "manifest.sh",
})

EXECUTABLE_SUFFIXES = (".sh", ".py", ".pl")


class PackageError(Exception):
    """A validation or packaging failure; message is operator-facing."""


@dataclasses.dataclass(frozen=True)
class ManifestRow:
    repo_path: str
    sha256: str
    status: str
    raw: str


@dataclasses.dataclass(frozen=True)
class BundleEntry:
    arcname: str
    data: bytes
    mode: int
    source: str | None


@dataclasses.dataclass(frozen=True)
class ReleaseResult:
    version: str
    archive: Path
    checksums: Path
    sha256: str
    file_count: int


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_version(text: str) -> str:
    version = text.strip()
    if not VERSION_RE.fullmatch(version):
        raise PackageError(
            f"invalid version {version!r}: expected semver like 0.1.0-alpha.1 "
            "(no leading 'v', no build metadata)"
        )
    return version


def is_safe_repo_path(path: str) -> bool:
    if not path or path.startswith("/") or "\\" in path:
        return False
    if any(ord(ch) < 0x20 or ch == "\x7f" for ch in path):
        return False
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return posixpath.normpath(path) == path


def parse_manifest(text: str) -> list[ManifestRow]:
    rows = []
    for lineno, line in enumerate(text.splitlines(), 1):
        first = line.split("\t", 1)[0]
        if not first.strip() or first.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 3:
            raise PackageError(
                f"manifest line {lineno}: expected repo_path<TAB>sha256<TAB>status"
            )
        repo_path, sha256, status = fields[0], fields[1], fields[2]
        if not is_safe_repo_path(repo_path):
            raise PackageError(f"manifest line {lineno}: unsafe path {repo_path!r}")
        if not SHA256_RE.fullmatch(sha256):
            raise PackageError(
                f"manifest line {lineno}: invalid sha256 for {repo_path}"
            )
        if status not in MANIFEST_STATUSES:
            raise PackageError(
                f"manifest line {lineno}: unknown status {status!r} for {repo_path}"
            )
        rows.append(ManifestRow(repo_path, sha256, status, line))
    if not rows:
        raise PackageError("manifest contains no rows")
    return rows


def is_runtime_origin(repo_path: str) -> bool:
    if repo_path in EXTRA_RUNTIME_ORIGINS:
        return True
    if repo_path.startswith(RUNTIME_ORIGIN_PREFIX) and "/" not in repo_path[len(RUNTIME_ORIGIN_PREFIX):]:
        return True
    if (repo_path.startswith(UI_SERVER_PREFIX)
            and "/" not in repo_path[len(UI_SERVER_PREFIX):]
            and repo_path.endswith(".py")):
        return True
    return False


def is_systemd_basename(basename: str) -> bool:
    return basename.endswith(SYSTEMD_SUFFIXES) or basename in SYSTEMD_HELPERS


def entry_mode(arcname: str) -> int:
    if arcname == "install-runtime.sh":
        return 0o755
    parent = posixpath.dirname(arcname)
    if parent in ("runtime", "systemd", "gov/.claude/hooks"):
        if arcname.endswith(EXECUTABLE_SUFFIXES):
            return 0o755
    return 0o644


class BundlePlan:
    def __init__(self, version: str, repo_root: Path | None = None):
        self.version = version
        self.repo_root = repo_root
        self.entries: dict[str, BundleEntry] = {}

    def add(self, arcname: str, *, source: Path | None = None,
            data: bytes | None = None) -> None:
        if not is_safe_repo_path(arcname):
            raise PackageError(f"unsafe bundle path: {arcname!r}")
        if (source is None) == (data is None):
            raise PackageError(f"entry {arcname}: exactly one of source/data required")
        src = str(source) if source is not None else None
        existing = self.entries.get(arcname)
        if existing is not None:
            if src is not None and existing.source == src:
                return  # same file selected twice (e.g. manifest + explicit list)
            raise PackageError(
                f"duplicate bundle path {arcname!r} "
                f"(from {existing.source or 'generated'} and {src or 'generated'})"
            )
        if source is not None:
            if self.repo_root is not None:
                current = self.repo_root
                for part in source.relative_to(self.repo_root).parts:
                    current = current / part
                    if current.is_symlink():
                        raise PackageError(f"unsafe: refusing to package symlink {current}")
            if source.is_symlink():
                raise PackageError(f"unsafe: refusing to package symlink {source}")
            data = source.read_bytes()
        assert data is not None
        self.entries[arcname] = BundleEntry(arcname, data, entry_mode(arcname), src)


def _require_file(repo_root: Path, rel: str, hint: str = "") -> Path:
    path = repo_root / rel
    if path.is_symlink():
        raise PackageError(f"unsafe: refusing to package symlink {rel}")
    if not path.is_file():
        raise PackageError(f"required file missing: {rel}{' — ' + hint if hint else ''}")
    return path


def _collect_manifest(plan: BundlePlan, repo_root: Path) -> None:
    manifest_path = _require_file(repo_root, MANIFEST_REL,
                                  "not a crewboss checkout?")
    rows = parse_manifest(manifest_path.read_text(encoding="utf-8"))

    runtime_rows: list[ManifestRow] = []
    seen_basenames: dict[str, str] = {}
    for row in rows:
        if row.status != "canonical" or not is_runtime_origin(row.repo_path):
            continue
        basename = posixpath.basename(row.repo_path)
        source = repo_root / row.repo_path
        if source.is_symlink():
            raise PackageError(f"unsafe: refusing to package symlink {row.repo_path}")
        if not source.is_file():
            raise PackageError(f"manifest file missing from checkout: {row.repo_path}")
        actual = sha256_file(source)
        if actual != row.sha256:
            raise PackageError(
                f"manifest hash mismatch for {row.repo_path}: "
                f"manifest {row.sha256}, file {actual} — regenerate the manifest"
            )
        if is_systemd_basename(basename):
            plan.add(f"systemd/{basename}", source=source)
            continue
        previous = seen_basenames.get(basename)
        if previous is not None:
            raise PackageError(
                f"duplicate deployment basename {basename!r}: "
                f"{previous} and {row.repo_path} would collide in CB_HOME"
            )
        seen_basenames[basename] = row.repo_path
        runtime_rows.append(row)
        plan.add(f"runtime/{basename}", source=source)

    missing = sorted(REQUIRED_RUNTIME_BASENAMES - set(seen_basenames))
    if missing:
        raise PackageError(
            "runtime bundle incomplete — no canonical manifest row from an "
            "allowed origin (reference/runtime/*, ui/server/*.py, "
            "reference/launcher allow-list) provides: " + ", ".join(missing)
            + " (prototype proto/* rows are ignored by design)"
        )

    shipped = "\n".join((
        f"# runtime-manifest.tsv — crewboss {plan.version} release manifest",
        "# Generated by scripts/package-release.py from reference/runtime-manifest.tsv.",
        "# Contains ONLY the canonical rows installed flat into CB_HOME so that",
        "# crewboss-doctor.sh drift-checks exactly the installed files.",
        "# repo_path keeps the source-repository origin; deployment is by basename.",
        "# repo_path\tsha256\tstatus\tpurpose",
        *(row.raw for row in runtime_rows),
    )) + "\n"
    plan.add("runtime/runtime-manifest.tsv", data=shipped.encode("utf-8"))


def _collect_systemd(plan: BundlePlan, repo_root: Path) -> None:
    for name in SYSTEMD_TEMPLATES + SYSTEMD_HELPERS:
        source = _require_file(repo_root, f"reference/runtime/{name}",
                               "systemd templates ship with the release")
        plan.add(f"systemd/{name}", source=source)


def _collect_team_and_gov(plan: BundlePlan, repo_root: Path) -> None:
    plan.add("team/org.json", source=_require_file(repo_root, "team-example/org.json"))
    plan.add("team/rubric.json",
             source=_require_file(repo_root, "team-example/rubric.json"))
    plan.add("team/manifest-doctor.sh",
             source=_require_file(repo_root, "team-example/manifest-doctor.sh"))

    roles = sorted((repo_root / "team-example/roles").glob("*.md"))
    if not roles:
        raise PackageError("required files missing: team-example/roles/*.md")
    for role in roles:
        plan.add(f"team/roles/{role.name}", source=role)

    plan.add("gov/.claude/settings.json",
             source=_require_file(repo_root, "reference/.claude/settings.json"))
    hooks = sorted((repo_root / "reference/.claude/hooks").glob("*.sh"))
    if not hooks:
        raise PackageError("required files missing: reference/.claude/hooks/*.sh")
    for hook in hooks:
        plan.add(f"gov/.claude/hooks/{hook.name}", source=hook)

    agents = sorted((repo_root / "reference/.claude/agents").glob("*.md"))
    if not agents:
        raise PackageError("required files missing: reference/.claude/agents/*.md")
    # Mirror deploy-runtime.sh team-catalog sync: gov/.claude/agents receives the
    # union of reference agents and team roles (the _cb_role_guard roots).
    # Team definitions are the configured catalog and take precedence when a
    # reference role has the same name, matching deploy-runtime.sh.
    catalog = {path.name: path for path in agents + roles}
    for name, path in sorted(catalog.items()):
        plan.add(f"gov/.claude/agents/{name}", source=path)


def _collect_ui(plan: BundlePlan, repo_root: Path) -> None:
    dist = repo_root / UI_DIST_REL
    if not (dist / "index.html").is_file():
        raise PackageError(
            f"built UI missing: {UI_DIST_REL}/index.html "
            "(run `npm ci && npm run build` in ui/app first)"
        )
    for path in sorted(dist.rglob("*")):
        rel = path.relative_to(dist).as_posix()
        parts = rel.split("/")
        if "node_modules" in parts:
            raise PackageError(f"unsafe: node_modules inside UI dist: {rel}")
        if any(part.startswith(".") for part in parts):
            continue  # host artifacts (.DS_Store, .vite, ...) never ship
        if path.is_symlink():
            raise PackageError(f"unsafe: symlink in UI dist: {rel}")
        if path.is_dir():
            continue
        plan.add(f"ui/{rel}", source=path)


def build_plan(repo_root: Path) -> BundlePlan:
    version = parse_version(
        _require_file(repo_root, "VERSION",
                      "the release version file must exist at the repo root"
                      ).read_text(encoding="utf-8"))
    plan = BundlePlan(version, repo_root)

    for name in ("LICENSE", "CHANGELOG.md"):
        plan.add(name, source=_require_file(repo_root, name))
    plan.add("README.md", data=(f"# crewboss {version}\n\n"
        "Experimental GitHub orchestration for coding agents. This archive contains\n"
        "the Linux x86_64 runtime and built dashboard.\n\n"
        "Read the [installation guide](docs/install.md) for dependencies, account\n"
        "configuration, sandbox checks and systemd setup. Install as the runtime\n"
        "account into an empty directory:\n\n"
        "```sh\nbash install-runtime.sh --prefix \"$HOME/cbnet\"\n```\n\n"
        "The installer verifies its payload and starts no services. Credentials\n"
        "are supplied separately by the operator.\n\n"
        "See the [changelog](CHANGELOG.md), [license](LICENSE), and\n"
        "[source repository, demo and contributor guides](https://github.com/ruslan-shaydullin/crewboss).\n"
        ).encode("utf-8"))
    plan.add("VERSION", data=(version + "\n").encode("utf-8"))
    plan.add("docs/install.md", source=_require_file(repo_root, "docs/install.md"))
    plan.add("install-runtime.sh",
             source=_require_file(repo_root, "scripts/install-runtime.sh"))
    plan.add("crewboss.env.example", source=_require_file(repo_root, ENV_EXAMPLE_REL))

    _collect_manifest(plan, repo_root)
    _collect_systemd(plan, repo_root)
    _collect_team_and_gov(plan, repo_root)
    _collect_ui(plan, repo_root)
    return plan


def _resolve_epoch(source_date_epoch: int | None) -> int:
    if source_date_epoch is None:
        raw = os.environ.get("SOURCE_DATE_EPOCH", "0")
        try:
            source_date_epoch = int(raw)
        except ValueError:
            raise PackageError(f"SOURCE_DATE_EPOCH must be an integer, got {raw!r}")
    if source_date_epoch < 0:
        raise PackageError("SOURCE_DATE_EPOCH must not be negative")
    return source_date_epoch


def write_archive(plan: BundlePlan, output_dir: Path, source_date_epoch: int
                  ) -> ReleaseResult:
    prefix = f"crewboss-{plan.version}"
    archive_name = f"{prefix}.tar.gz"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / archive_name

    directories = {prefix}
    for arcname in plan.entries:
        parent = posixpath.dirname(arcname)
        while parent:
            directories.add(f"{prefix}/{parent}")
            parent = posixpath.dirname(parent)

    members = sorted(directories) + sorted(
        f"{prefix}/{name}" for name in plan.entries)
    members.sort()

    tmp_path = output_dir / (archive_name + ".tmp")
    with open(tmp_path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw,
                           compresslevel=9, mtime=source_date_epoch) as gz:
            with tarfile.open(fileobj=gz, mode="w",
                              format=tarfile.GNU_FORMAT) as tar:
                for name in members:
                    info = tarfile.TarInfo(name)
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    info.mtime = source_date_epoch
                    if name in directories:
                        info.type = tarfile.DIRTYPE
                        info.mode = 0o755
                        tar.addfile(info)
                    else:
                        entry = plan.entries[name[len(prefix) + 1:]]
                        info.size = len(entry.data)
                        info.mode = entry.mode
                        tar.addfile(info, io.BytesIO(entry.data))
    os.replace(tmp_path, archive_path)

    digest = sha256_file(archive_path)
    checksums_path = output_dir / "SHA256SUMS"
    checksums_path.write_text(f"{digest}  {archive_name}\n", encoding="utf-8")
    return ReleaseResult(plan.version, archive_path, checksums_path, digest,
                         len(plan.entries))


def build_release(repo_root, output_dir=None, source_date_epoch=None
                  ) -> ReleaseResult:
    repo_root = Path(repo_root).resolve()
    epoch = _resolve_epoch(source_date_epoch)

    if output_dir is None:
        # Default output lives OUTSIDE the source tree — never pollute a
        # (possibly shared) checkout unless the operator asks with --output.
        output_dir = Path(tempfile.mkdtemp(prefix="crewboss-dist-"))
    else:
        output_dir = Path(output_dir).resolve()
        if output_dir.is_relative_to(repo_root / UI_DIST_REL):
            raise PackageError(
                "unsafe --output: it would be packaged into the bundle "
                f"(inside {UI_DIST_REL})"
            )

    plan = build_plan(repo_root)
    internal = "".join(
        f"{sha256_bytes(entry.data)}  {arcname}\n"
        for arcname, entry in sorted(plan.entries.items())
    )
    plan.add("SHA256SUMS", data=internal.encode("utf-8"))
    return write_archive(plan, output_dir, epoch)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="package-release.py",
        description="Build the deterministic crewboss release archive "
                    "(version from the repo-root VERSION file).")
    parser.add_argument("--repo-root", type=Path,
                        default=Path(__file__).resolve().parent.parent,
                        help="crewboss checkout root (default: this script's repo)")
    parser.add_argument("--output", type=Path, default=None,
                        help="output directory (default: a fresh directory "
                             "under the system temp dir, outside the source tree)")
    args = parser.parse_args(argv)
    try:
        result = build_release(args.repo_root, output_dir=args.output)
    except PackageError as exc:
        print(f"package-release: error: {exc}", file=sys.stderr)
        return 2
    print(f"version:   {result.version}")
    print(f"archive:   {result.archive}")
    print(f"sha256:    {result.sha256}")
    print(f"checksums: {result.checksums}")
    print(f"files:     {result.file_count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
