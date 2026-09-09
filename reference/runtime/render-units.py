#!/usr/bin/env python3
"""Render reviewed systemd templates for an unprivileged runtime account."""
import argparse
from pathlib import Path
import re


def absolute_path(value):
    # These paths also travel over SSH. Reject shell/systemd metacharacters
    # explicitly instead of interpreting them during installation.
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", value) or ".." in Path(value).parts:
        raise argparse.ArgumentTypeError("use an absolute path without spaces or shell/systemd metacharacters")
    return value.rstrip("/")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--user", default="crewboss")
    parser.add_argument("--home", default="/var/lib/crewboss", type=absolute_path)
    parser.add_argument("--runtime-dir", type=absolute_path)
    parser.add_argument("--env-file", type=absolute_path)
    parser.add_argument("--template-dir", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*[$]?", args.user) or args.user == "root":
        parser.error("--user must name an unprivileged Linux service account")
    runtime = args.runtime_dir or args.home + "/cbnet"
    env_file = args.env_file or args.home + "/.crewboss.env"
    replacements = {
        "/var/lib/crewboss/cbnet": runtime,
        "/var/lib/crewboss/.crewboss.env": env_file,
        "/var/lib/crewboss": args.home,
        "User=crewboss": "User=" + args.user,
        "Group=crewboss": "Group=" + args.user,
    }
    pattern = re.compile("|".join(re.escape(key) for key in replacements))
    templates = args.template_dir or Path(__file__).resolve().parent
    if not (templates / "crewboss-api.service").exists():
        templates = templates / "systemd"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        "crewboss-api.service", "crewboss-launcher.service",
        "crewboss-loop-keepalive.service", "crewboss-loop-keepalive.timer",
        "crewboss-loop-keepalive-killmode.conf",
    ):
        source = (templates / name).read_text()
        (args.output_dir / name).write_text(pattern.sub(lambda m: replacements[m.group()], source))


if __name__ == "__main__":
    main()
