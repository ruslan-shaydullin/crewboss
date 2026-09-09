#!/usr/bin/env python3
"""Offline configuration/preflight/spawn contracts with recording tool fixtures."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


RUNTIME = Path(__file__).resolve().parents[1] / "runtime"
BASH = os.environ.get("CB_TEST_BASH", shutil.which("bash") or "/bin/bash")


class RuntimePortabilityTests(unittest.TestCase):
    def setUp(self):
        # Keep Unix socket paths below the platform's 104/108-byte limit.
        self.temp = tempfile.TemporaryDirectory(prefix="cb-portability-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "operator"
        self.runtime = self.root / "custom runtime"
        self.install = self.root / "provider installation"
        self.config_dir = self.home / "provider config"
        self.config_file = self.home / "provider.json"
        self.bin = self.root / "bin"
        for directory in (self.home, self.runtime, self.install, self.config_dir, self.bin):
            directory.mkdir(parents=True)
        self.config_file.write_text("{}")
        for name in ("run-env.sh", "crewboss-doctor.sh", "crewboss-spawn.sh", "redact.pl", "claude.kafel"):
            shutil.copyfile(RUNTIME / name, self.runtime / name)
        for name in ("bridge.py", "crewboss-launcher-gh.sh"):
            (self.runtime / name).touch()
        governance = self.runtime / "gov/.claude"
        (governance / "hooks").mkdir(parents=True)
        shutil.copy2(RUNTIME.parent / ".claude/hooks/crewboss-gate.sh", governance / "hooks/crewboss-gate.sh")
        shutil.copyfile(RUNTIME.parent / ".claude/settings.json", governance / "settings.json")
        # A local Unix socket fixture; it never contacts any external service.
        (self.runtime / "proxy.py").write_text(
            "import socket,sys,time\nsock=socket.socket(socket.AF_UNIX)\n"
            "sock.bind(sys.argv[1])\ntime.sleep(60)\n"
        )
        self.provider = self.install / "claude"
        self.provider.write_text("#!/bin/sh\nexit 99\n")
        self.provider.chmod(0o755)
        self.record = self.root / "jail.jsonl"
        self.gh_record = self.root / "gh-called"
        self.write_tool("uname", "import sys\nprint('Linux' if sys.argv[-1]=='-s' else 'x86_64')\n")
        self.write_tool("nsjail", '''import json,os,sys
from pathlib import Path
with Path(os.environ["TEST_JAIL_RECORD"]).open("a") as stream:
    stream.write(json.dumps(sys.argv[1:])+"\\n")
if sys.argv[-1] != "/bin/true":
    print('{"total_cost_usd":0.125,"is_error":false}')
sys.exit(int(os.environ.get("TEST_JAIL_EXIT", "0")))
''')
        self.write_tool("gh", "from pathlib import Path\nimport os\nPath(os.environ['TEST_GH_RECORD']).touch()\nraise SystemExit(99)\n")
        # Only locking is stubbed on macOS; Linux integration verifies real flock.
        self.write_tool("flock", "raise SystemExit(0)\n")
        (self.bin / "python3").symlink_to(sys.executable)
        (self.bin / "bash").symlink_to(BASH)
        self.env = {
            "HOME": str(self.home), "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "CB_HOME": str(self.runtime), "CB_ENV_FILE": "/dev/null", "CB_REPO": "another-owner/project",
            "GH_TOKEN": "fixture-github", "CLAUDE_CODE_OAUTH_TOKEN": "fixture-agent",
            "CB_AGENT_HOME": str(self.home), "CB_CLAUDE_BIN": str(self.provider),
            "CB_CLAUDE_INSTALL_DIR": str(self.install), "CB_CLAUDE_CONFIG_DIR": str(self.config_dir),
            "CB_CLAUDE_CONFIG_FILE": str(self.config_file), "CB_NSJAIL_BIN": str(self.bin / "nsjail"),
            "CB_GH_BIN": str(self.bin / "gh"), "TEST_JAIL_RECORD": str(self.record),
            "TEST_GH_RECORD": str(self.gh_record),
        }

    def write_tool(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    def source_env(self):
        return subprocess.run(
            [BASH, "-c", 'source "$1" || exit $?; env -0', "fixture", str(self.runtime / "run-env.sh")],
            env=self.env, capture_output=True, timeout=10,
        )

    def doctor(self):
        return subprocess.run([BASH, str(self.runtime / "crewboss-doctor.sh"), "--preflight"],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def jail_calls(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def test_config_preserves_custom_home_and_never_extracts_token(self):
        result = self.source_env()
        self.assertEqual(result.returncode, 0, result.stderr)
        env = dict(item.split(b"=", 1) for item in result.stdout.split(b"\0") if item)
        self.assertEqual(env[b"CB_HOME"], str(self.runtime).encode())
        self.assertEqual(env[b"CB_SPAWN"], str(self.runtime / "charter-leaf-prep.sh").encode())
        self.assertFalse(self.gh_record.exists())

    def test_explicit_config_file_outside_home_is_used(self):
        config = self.root / "operator.env"
        config.write_text("CB_REPO=configured-owner/project\nGH_TOKEN=configured-fixture\n")
        self.env["CB_ENV_FILE"] = str(config)
        result = self.source_env()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"CB_REPO=configured-owner/project\0", result.stdout)
        self.assertIn(b"GH_TOKEN=configured-fixture\0", result.stdout)

    def test_missing_configuration_fails_before_sandbox_or_github(self):
        for key, value in (("CB_REPO", ""), ("CB_HOME", "relative"), ("CB_ENV_FILE", str(self.root / "absent.env"))):
            with self.subTest(key=key):
                old = self.env[key]
                self.env[key] = value
                result = self.doctor()
                self.env[key] = old
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)
                self.assertFalse(self.record.exists())
                self.assertFalse(self.gh_record.exists())

    def test_preflight_probes_real_policy_and_readonly_provider_mounts(self):
        result = self.doctor()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.jail_calls()[0]
        self.assertEqual(args[-2:], ["--", "/bin/true"])
        self.assertEqual(args[args.index("--seccomp_policy") + 1], str(self.runtime / "claude.kafel"))
        self.assertIn(str(self.install), args)
        self.assertEqual(args[args.index(str(self.install)) - 1], "-R")
        self.assertFalse(self.gh_record.exists())

    def test_unsupported_architecture_fails_without_namespace_attempt(self):
        self.write_tool("uname", "import sys\nprint('Linux' if sys.argv[-1]=='-s' else 'aarch64')\n")
        result = self.doctor()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("x86_64 only", result.stderr)
        self.assertFalse(self.record.exists())

    def test_invalid_provider_or_missing_credentials_fail_before_github(self):
        for key, value in (("CB_CLAUDE_BIN", "/absent/claude"), ("GH_TOKEN", ""), ("CLAUDE_CODE_OAUTH_TOKEN", "")):
            with self.subTest(key=key):
                old = self.env[key]
                self.env[key] = value
                result = self.doctor()
                self.env[key] = old
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.record.exists())
                self.assertFalse(self.gh_record.exists())

    def test_namespace_failure_is_reported(self):
        self.env["TEST_JAIL_EXIT"] = "1"
        result = self.doctor()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nsjail probe failed", result.stderr)
        self.assertFalse(self.gh_record.exists())

    def test_operator_entrypoints_fail_preflight_before_board_calls(self):
        self.env["GH_TOKEN"] = ""
        (self.runtime / "labels-setup.sh").write_text("#!/bin/sh\ngh label create fixture\n")
        (self.runtime / "board-gh.sh").write_text("#!/bin/sh\ngh issue view 42\n")
        for name, arguments in (("run-charter.sh", ["--foreground"]), ("crewboss-prep-spawn-gh.sh", ["42", "executor"])):
            with self.subTest(entrypoint=name):
                shutil.copyfile(RUNTIME / name, self.runtime / name)
                result = subprocess.run([BASH, str(self.runtime / name), *arguments], env=self.env,
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("GH_TOKEN is required", result.stderr)
                self.assertFalse(self.gh_record.exists())
                self.assertFalse(self.record.exists())

    def test_spawn_preserves_mount_restrictions_budget_and_private_status(self):
        work = self.root / "checkout"
        work.mkdir()
        prompt = self.root / "prompt"
        prompt.write_text("fixture task")
        self.env.update(CB_FS_WORK="ro", CB_FS_CBNET="ro")
        result = subprocess.run([BASH, str(self.runtime / "crewboss-spawn.sh"), "17", "executor", str(prompt), str(work), "another-owner/project"],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        args = self.jail_calls()[-1]
        for path in (str(work) + ":/work", str(self.runtime) + ":/cbnet"):
            self.assertEqual(args[args.index(path) - 1], "-R")
        run_mount = str(self.runtime / "run") + ":/cbnet/run"
        self.assertEqual(args[args.index(run_mount) - 1], "-B")
        self.assertIn("--seccomp_policy", args)
        self.assertIn("HTTPS_PROXY=http://127.0.0.1:3128", args)
        self.assertIn("CB_GH_REAL=/crewboss-gh-real", args)
        status = self.runtime / "run/work/17/status.json"
        self.assertEqual(json.loads(status.read_text())["phase"], "done")
        self.assertEqual(status.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((self.runtime / "run/budget.json").read_text())["spent_usd"], 0.125)
        self.assertFalse((work / ".task.prompt").exists())
        self.assertFalse(self.gh_record.exists())

    def test_exhausted_budget_never_starts_agent(self):
        work = self.root / "checkout"
        work.mkdir()
        prompt = self.root / "prompt"
        prompt.write_text("fixture task")
        run = self.runtime / "run"
        run.mkdir()
        (run / "budget.json").write_text('{"spent_usd":81,"runs":[]}')
        result = subprocess.run([BASH, str(self.runtime / "crewboss-spawn.sh"), "18", "executor", str(prompt), str(work)],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertTrue(all(args[-1] == "/bin/true" for args in self.jail_calls()))
        self.assertEqual(json.loads((run / "work/18/status.json").read_text())["phase"], "budget-stop")

    def test_unit_renderer_supports_custom_account_runtime_and_config(self):
        rendered = self.root / "units"
        result = subprocess.run([sys.executable, str(RUNTIME / "render-units.py"), "--output-dir", str(rendered),
                                 "--user", "operator", "--home", "/srv/operator", "--runtime-dir", "/srv/runtime", "--env-file", "/etc/operator.env"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("crewboss-api.service", "crewboss-launcher.service"):
            unit = (rendered / name).read_text()
            self.assertIn("User=operator", unit)
            self.assertIn("WorkingDirectory=/srv/runtime", unit)
            self.assertIn("EnvironmentFile=/etc/operator.env", unit)
            self.assertNotIn("ec2-user", unit)
        keepalive = (rendered / "crewboss-loop-keepalive.service").read_text()
        self.assertIn("ExecStart=/usr/bin/systemctl start crewboss-launcher.service", keepalive)
        self.assertNotIn("/srv/runtime/", keepalive)

    def test_real_proxy_uses_task_local_log_and_denies_unlisted_destination(self):
        sock_path = self.root / "task/proxy.sock"
        process = subprocess.Popen([sys.executable, str(RUNTIME / "proxy.py"), str(sock_path)],
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not sock_path.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(sock_path.exists(), "proxy did not create the configured socket")
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(2)
                client.connect(str(sock_path))
                client.sendall(b"CONNECT disallowed.example:443 HTTP/1.1\r\n\r\n")
                self.assertIn(b"403 Forbidden", client.recv(1024))
            self.assertIn("DENY disallowed.example:443", (sock_path.parent / "proxy.log").read_text())
            self.assertEqual(sock_path.stat().st_mode & 0o777, 0o600)
        finally:
            process.terminate()
            process.communicate(timeout=5)

    def test_rework_preserves_owning_role_and_token_free_remote(self):
        shutil.copyfile(RUNTIME / "rework-prep.sh", self.runtime / "rework-prep.sh")
        self.write_tool("gh", '''import sys
if sys.argv[1:3] == ["auth", "token"]: raise SystemExit(99)
if "body" in sys.argv: print("Charter: #101")
''')
        self.write_tool("git", '''import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with Path(os.environ["TEST_GIT_RECORD"]).open("a") as out: out.write(json.dumps(args)+"\\n")
if args[0]=="clone": (Path(args[-1])/".git/info").mkdir(parents=True)
''')
        spawn = self.runtime / "crewboss-spawn.sh"
        spawn.write_text(f"#!{sys.executable}\n" + '''import json,os,sys
from pathlib import Path
Path(os.environ["TEST_SPAWN_RECORD"]).write_text(json.dumps(sys.argv[1:]))
''')
        spawn.chmod(0o755)
        git_record = self.root / "git.jsonl"
        spawn_record = self.root / "spawn.json"
        self.env.update(TEST_GIT_RECORD=str(git_record), TEST_SPAWN_RECORD=str(spawn_record))
        result = subprocess.run([BASH, str(self.runtime / "rework-prep.sh"), "42", "qa-engineer"],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(spawn_record.read_text())[:2], ["42", "qa-engineer"])
        self.assertNotIn(self.env["GH_TOKEN"], git_record.read_text())
        self.assertIn("https://github.com/another-owner/project.git", git_record.read_text())
        self.assertTrue((self.runtime / "run/work/42/repo/work/.claude/hooks/crewboss-gate.sh").exists())

    def test_unit_deploy_uploads_rendered_files_through_private_staging(self):
        uploads = self.root / "uploads.jsonl"
        self.env.update(CB_HOST="example.invalid", CB_SERVICE_USER="operator", CB_SERVICE_HOME="/srv/operator",
                        CB_REMOTE_HOME="/srv/runtime", CB_REMOTE_ENV_FILE="/etc/operator.env", TEST_UPLOADS=str(uploads))
        self.write_tool("ssh", '''import sys
if "mktemp -d" in sys.argv[-1]: print("/tmp/crewboss-units.FIXTURE")
''')
        self.write_tool("scp", '''import json,os,sys
from pathlib import Path
source=Path(sys.argv[-2])
with Path(os.environ["TEST_UPLOADS"]).open("a") as out:
    out.write(json.dumps({"name":source.name,"body":source.read_text(),"target":sys.argv[-1]})+"\\n")
''')
        result = subprocess.run([BASH, str(RUNTIME / "deploy-units.sh")], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        sent = [json.loads(line) for line in uploads.read_text().splitlines()]
        self.assertEqual(len(sent), 5)
        for upload in sent:
            self.assertEqual(upload["target"], "example.invalid:/tmp/crewboss-units.FIXTURE/unit")
            if upload["name"] in ("crewboss-api.service", "crewboss-launcher.service"):
                self.assertIn("User=operator", upload["body"])
                self.assertIn("EnvironmentFile=/etc/operator.env", upload["body"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
