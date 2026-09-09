#!/usr/bin/env python3
"""Offline startup contracts; no GitHub credentials, network, or systemd needed."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


RUNTIME = Path(__file__).resolve().parents[1] / "runtime"
START = RUNTIME / "start-api.sh"


def service_settings():
    settings = {}
    for line in (RUNTIME / "crewboss-api.service").read_text().splitlines():
        if line and not line.startswith(("#", "[")) and "=" in line:
            key, value = line.split("=", 1)
            settings.setdefault(key, []).append(value)
    return settings


class ApiStartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="crewboss-startup-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime with spaces"
        self.runtime.mkdir()
        self.api = self.runtime / "crewboss-api.py"
        self.api.touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.record = self.root / "api.json"
        self.curl_record = self.root / "curl.json"
        self.env = {
            "HOME": str(self.root),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "CB_HOME": str(self.runtime),
            "CB_REPO": "example/project",
            "CB_API_TOKEN": "fixture-bearer-token",
            "TEST_RECORD": str(self.record),
            "TEST_CURL_RECORD": str(self.curl_record),
        }
        self.write_tool("python3", '''import json, os, sys, time
from pathlib import Path
keys = ("CB_HOME", "CB_REPO", "CB_API_TOKEN", "CB_API_HOST", "CB_API_PORT",
        "CB_SPAWN", "CB_GOVERNED", "CB_WEBHOOK_SECRET", "GH_TOKEN")
Path(os.environ["TEST_RECORD"]).write_text(json.dumps({
    "argv": sys.argv[1:], "env": {key: os.environ.get(key) for key in keys}}))
if os.environ.get("TEST_MODE") == "background":
    time.sleep(60)
sys.exit(int(os.environ.get("TEST_EXIT", "0")))
''')
        self.write_tool("curl", '''import json, os, sys
from pathlib import Path
Path(os.environ["TEST_CURL_RECORD"]).write_text(json.dumps(sys.argv[1:]))
sys.exit(0)
''')
        # Any unexpected attempt to look up operator credentials fails the test.
        self.write_tool("gh", 'raise SystemExit("gh must not run during startup")\n')
        self.addCleanup(self.stop_started_api)

    def write_tool(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o755)

    def run_start(self, *args):
        return subprocess.run(
            ["/bin/bash", str(START), *args], env=self.env,
            capture_output=True, text=True, timeout=15,
        )

    def stop_started_api(self):
        pid_file = self.runtime / "run" / "api.pid"
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except (ProcessLookupError, ValueError):
                pass
            pid_file.unlink()

    def test_requires_repository_and_nonblank_token_before_launch(self):
        for name, value in (("CB_REPO", ""), ("CB_API_TOKEN", ""), ("CB_API_TOKEN", " \t")):
            with self.subTest(name=name, value=value):
                original = self.env[name]
                self.env[name] = value
                result = self.run_start("--foreground")
                self.env[name] = original
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name, result.stderr)
                self.assertFalse(self.record.exists())

    def test_explicit_missing_configuration_fails(self):
        self.env["CB_ENV_FILE"] = str(self.root / "missing.env")
        result = self.run_start("--foreground")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CB_ENV_FILE does not exist", result.stderr)
        self.assertFalse(self.record.exists())

    def test_defaults_bind_loopback_without_inventing_credentials(self):
        result = self.run_start("--foreground")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["env"]["CB_API_HOST"], "127.0.0.1")
        self.assertEqual(record["env"]["CB_API_PORT"], "8787")
        self.assertEqual(record["env"]["CB_API_TOKEN"], self.env["CB_API_TOKEN"])
        self.assertIsNone(record["env"]["CB_WEBHOOK_SECRET"])
        self.assertEqual(record["env"]["GH_TOKEN"], "")
        self.assertNotIn(self.env["CB_API_TOKEN"], result.stdout + result.stderr)

    def test_trusted_config_assignments_are_exported(self):
        config = self.root / ".crewboss.env"
        config.write_text(
            "CB_REPO=config/project\nCB_API_TOKEN=config-fixture-token\n"
            "CB_API_HOST=0.0.0.0\nCB_API_PORT=9091\n"
            "GH_TOKEN=fixture-github-token\nCB_WEBHOOK_SECRET=fixture-webhook-secret\n"
        )
        result = self.run_start("--foreground")
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record.read_text())
        self.assertEqual(record["env"]["CB_REPO"], "config/project")
        self.assertEqual(record["env"]["CB_API_TOKEN"], "config-fixture-token")
        self.assertEqual(record["env"]["GH_TOKEN"], "fixture-github-token")
        self.assertEqual(record["env"]["CB_WEBHOOK_SECRET"], "fixture-webhook-secret")
        self.assertEqual(record["argv"], [str(self.api), "--port", "9091"])

    def test_api_path_and_port_can_be_overridden(self):
        checkout_api = self.root / "checkout api.py"
        checkout_api.touch()
        self.env.update(CB_ENV_FILE="/dev/null", CB_API_SCRIPT=str(checkout_api), CB_API_PORT="9092")
        result = self.run_start("--foreground")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["argv"], [str(checkout_api), "--port", "9092"])

    def test_invalid_ports_are_rejected(self):
        for port in ("0", "65536", "-1", "abc", "12;false", "99999999999999"):
            with self.subTest(port=port):
                self.env["CB_API_PORT"] = port
                result = self.run_start("--foreground")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CB_API_PORT", result.stderr)
                self.assertFalse(self.record.exists())

    def test_foreground_propagates_daemon_failure(self):
        self.env["TEST_EXIT"] = "17"
        self.assertEqual(self.run_start("--foreground").returncode, 17)

    def test_background_failure_removes_pid_and_reports_log(self):
        self.env["TEST_EXIT"] = "17"
        result = self.run_start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("API exited during startup", result.stderr)
        self.assertFalse((self.runtime / "run" / "api.pid").exists())
        self.assertTrue((self.runtime / "run" / "api.out").exists())

    def test_background_health_uses_configured_port_and_local_host(self):
        self.env.update(TEST_MODE="background", CB_API_HOST="0.0.0.0", CB_API_PORT="9093")
        result = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        curl_args = json.loads(self.curl_record.read_text())
        self.assertEqual(curl_args[-1], "http://127.0.0.1:9093/api/health")
        self.assertIn("--fail", curl_args)
        self.assertIn("--noproxy", curl_args)
        pid_file = self.runtime / "run" / "api.pid"
        self.assertEqual(pid_file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.env["CB_API_TOKEN"], result.stdout + result.stderr)

    def test_existing_live_pid_is_not_killed(self):
        # This process is known to exist; startup must not signal or replace it.
        (self.runtime / "run").mkdir()
        pid_file = self.runtime / "run" / "api.pid"
        pid_file.write_text(str(os.getpid()))
        try:
            result = self.run_start()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already uses", result.stderr)
            self.assertFalse(self.record.exists())
            self.assertEqual(pid_file.read_text(), str(os.getpid()))
        finally:
            pid_file.unlink(missing_ok=True)

    def test_example_configuration_cannot_start_unedited(self):
        self.env["CB_ENV_FILE"] = str(RUNTIME / "api.env.example")
        result = self.run_start("--foreground")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_system_service_uses_same_guarded_foreground_entrypoint(self):
        settings = service_settings()
        command = shlex.split(settings["ExecStart"][0])
        self.assertEqual(command, ["/bin/bash", "/var/lib/crewboss/cbnet/start-api.sh", "--foreground"])
        self.assertEqual(settings["EnvironmentFile"], ["/var/lib/crewboss/.crewboss.env"])
        self.assertIn("CB_ENV_FILE=/var/lib/crewboss/.crewboss.env", settings["Environment"])
        self.assertIn("CB_API_HOST=127.0.0.1", settings["Environment"])
        self.assertNotIn("root", settings["User"])

    def test_service_run_actions_retain_shared_operator_configuration(self):
        # Relocate the actual service template to a temporary account. Using its
        # configured paths catches divergence between daemon and launcher setup.
        settings = service_settings()
        service_env = dict(item.split("=", 1) for item in settings["Environment"])
        template_home = service_env["HOME"]
        fixture_home = self.root / "service-account"
        self.assertEqual(settings["EnvironmentFile"], [template_home + "/.crewboss.env"])
        service_env = {key: value.replace(template_home, str(fixture_home))
                       for key, value in service_env.items()}
        service_env["PATH"] = self.env["PATH"]
        deployed = Path(service_env["CB_HOME"])
        self.assertEqual(deployed, fixture_home / "cbnet")
        self.assertEqual(settings["WorkingDirectory"], [template_home + "/cbnet"])
        # Exercise the supported overrides as well as the template's defaults:
        # neither runtime nor configuration needs to live under account HOME.
        default_deployed = deployed
        deployed = self.root / "separate-runtime"
        service_env["CB_HOME"] = str(deployed)
        shared_config = self.root / "operator.env"
        service_env["CB_ENV_FILE"] = str(shared_config)
        deployed.mkdir(parents=True)
        shutil.copyfile(RUNTIME / "run-env.sh", deployed / "run-env.sh")
        (deployed / "crewboss-doctor.sh").write_text(
            '#!/bin/sh\n[ "$1" = --preflight ] && [ "$GH_TOKEN" = fixture-shared-github ]\n'
        )

        # The real shared example uses literal assignments understood by systemd
        # and bash. Fill in fixture credentials and keep the rest of that file.
        config = (RUNTIME / "api.env.example").read_text().replace(template_home, str(fixture_home))
        config = config.replace(str(default_deployed), str(deployed))
        config = config.replace("\nCB_REPO=\n", "\nCB_REPO=custom-owner/custom-project\n")
        config = config.replace("\nCB_API_TOKEN=\n", "\nCB_API_TOKEN=fixture-service-bearer\n")
        config += "\nGH_TOKEN=fixture-shared-github\nCLAUDE_CODE_OAUTH_TOKEN=fixture-shared-agent\n"
        shared_config.write_text(config)
        for line in config.splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("=", 1)
                service_env[key] = value

        api_path = RUNTIME.parents[1] / "ui" / "server" / "crewboss-api.py"
        spec = importlib.util.spec_from_file_location("crewboss_api_service_contract", api_path)
        api = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, service_env, clear=True):
            spec.loader.exec_module(api)
            calls = []

            def record_launcher(args, **kwargs):
                calls.append((args, kwargs["env"]))
                kwargs["stdout"].close()
                return types.SimpleNamespace(pid=987654, returncode=0, wait=lambda: 0)

            # Keep the real shell env-building operation; only replace the final
            # launcher process. The API's clean HOME/PATH seed must recover all
            # operator values through the deployed, unmodified run-env.sh.
            api.subprocess = types.SimpleNamespace(
                run=subprocess.run, Popen=record_launcher, STDOUT=subprocess.STDOUT,
            )
            for action in ("run", "run-scoped"):
                with self.subTest(action=action):
                    result = api.do_command({"action": action, "number": 42})
                    self.assertTrue(result["ok"], result)
                    launch_env = calls[-1][1]
                    self.assertEqual(launch_env["CB_REPO"], "custom-owner/custom-project")
                    self.assertEqual(launch_env["GH_TOKEN"], "fixture-shared-github")
                    self.assertEqual(launch_env["CLAUDE_CODE_OAUTH_TOKEN"], "fixture-shared-agent")
                    self.assertEqual(launch_env["CB_HOME"], api.CB_HOME)
                    self.assertEqual(launch_env["CB_HOME"], str(deployed))
                    if action == "run-scoped":
                        self.assertEqual(launch_env["CREWBOSS_CHARTER"], "42")
            self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
