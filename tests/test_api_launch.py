"""Configuration and preflight failure must not dispatch a launcher."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import threading
from concurrent.futures import ThreadPoolExecutor
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("crewboss_launch_test_api", ROOT / "ui/server/crewboss-api.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ApiLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="crewboss-api-launch-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.runtime = self.home / "runtime with spaces"
        self.runtime.mkdir()
        self.config = self.home / "operator.env"
        self.config.write_text("CB_MAX_PARALLEL=7\nCB_CLAUDE_BIN=/custom/claude\n")
        self.source = self.runtime / "run-env.sh"
        self.source.write_text('. "$CB_ENV_FILE"\nexport CB_MAX_PARALLEL CB_CLAUDE_BIN\n')
        self.doctor = self.runtime / "crewboss-doctor.sh"
        self.doctor.write_text('[ "$1" = --preflight ]\n')
        self.environment = patch.dict(os.environ, {
            "HOME": str(self.home), "CB_HOME": str(self.runtime), "CB_REPO": "fixture/repository",
            "CB_ENV_FILE": str(self.config), "CB_API_TOKEN": "fixture-private-token",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.attributes = patch.multiple(api, CB_HOME=str(self.runtime), REPO="fixture/repository",
                                         RUN=str(self.runtime / "run"))
        self.attributes.start()
        self.addCleanup(self.attributes.stop)

    def test_custom_paths_config_and_overrides_survive_environment_rebuild(self):
        environment = api.launcher_environment(str(self.runtime), "fixture/repository")
        self.assertEqual(environment["CB_HOME"], str(self.runtime))
        self.assertEqual(environment["CB_REPO"], "fixture/repository")
        self.assertEqual(environment["CB_ENV_FILE"], str(self.config))
        self.assertEqual(environment["CB_MAX_PARALLEL"], "7")
        self.assertEqual(environment["CB_CLAUDE_BIN"], "/custom/claude")

    def test_failed_source_or_preflight_cannot_dispatch_or_leave_scoped_lock(self):
        for stage in ("source", "preflight"):
            failing = self.source if stage == "source" else self.doctor
            original = failing.read_text()
            failing.write_text('echo "$CB_API_TOKEN"\nexit 2\n')
            for action in ("run", "run-scoped"):
                from types import SimpleNamespace
                dispatcher = SimpleNamespace(Popen=unittest.mock.Mock())
                with patch.object(api, "subprocess", dispatcher):
                    result = api.do_command({"action": action, "number": 42})
                self.assertFalse(result["ok"], (stage, action, result))
                dispatcher.Popen.assert_not_called()
                self.assertNotIn("fixture-private-token", str(result))
                self.assertFalse((self.runtime / "run/scoped_charter").exists())
            failing.write_text(original)

    def test_changed_runtime_or_repository_requires_api_restart(self):
        for variable, value in (("CB_HOME", "/different/runtime"), ("CB_REPO", "different/repository")):
            self.config.write_text(f"{variable}={value}\n")
            with self.assertRaisesRegex(RuntimeError, "restart the API"):
                api.launcher_environment(str(self.runtime), "fixture/repository")

    def test_scope_wrapper_quotes_paths_and_config_is_loaded_before_lock(self):
        from types import SimpleNamespace
        launcher = unittest.mock.Mock(return_value=SimpleNamespace(pid=12345, returncode=0, wait=lambda: 0))
        with patch.object(api, "subprocess", SimpleNamespace(Popen=launcher, STDOUT=-2)):
            result = api.do_command({"action": "run-scoped", "number": 42})
        self.assertTrue(result["ok"], result)
        command = launcher.call_args.args[0]
        self.assertEqual(command[-2], str(self.runtime / "crewboss-launcher-gh.sh"))
        self.assertEqual(command[-1], str(self.runtime / "run/scoped_charter"))
        self.assertEqual(launcher.call_args.kwargs["env"]["CREWBOSS_CHARTER"], "42")
        launcher.call_args.kwargs["stdout"].close()

    def test_short_lived_children_are_reaped_without_another_popen(self):
        import subprocess
        from types import SimpleNamespace

        (self.runtime / "crewboss-launcher-gh.sh").write_text('sleep 0.05\nexit 7\n')
        for action in ("run", "run-scoped"):
            with self.subTest(action=action):
                children = []

                def start_child(*args, **kwargs):
                    process = subprocess.Popen(*args, **kwargs)
                    children.append(process)
                    return process

                def cleanup_child(children=children):
                    for process in children:
                        if process.returncode is None:
                            process.kill()
                            process.wait()

                self.addCleanup(cleanup_child)
                dispatcher = SimpleNamespace(Popen=unittest.mock.Mock(side_effect=start_child),
                                             STDOUT=subprocess.STDOUT)
                # No environment loader or follow-up subprocess may accidentally
                # reap an abandoned Popen; the only process is the launcher.
                with patch.object(api, "subprocess", dispatcher), patch.object(
                    api, "launcher_environment", return_value=dict(os.environ)
                ):
                    result = api.do_command({"action": action, "number": 42})
                    self.assertTrue(result["ok"], result)
                    dispatcher.Popen.assert_called_once()
                    child = children[0]
                    deadline = time.monotonic() + 3
                    while child.returncode is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    # Inspect the attribute only: poll()/wait() here would hide
                    # the exact zombie leak this regression is meant to catch.
                    self.assertEqual(child.returncode, 7)
                    with self.assertRaises(ChildProcessError):
                        os.waitpid(child.pid, os.WNOHANG)
                    if action == "run-scoped":
                        self.assertFalse((self.runtime / "run/scoped_charter").exists())

    def test_scoped_start_rejects_existing_live_launcher_without_overwriting_pid(self):
        run = self.runtime / "run"
        run.mkdir()
        pid_file = run / "launcher.pid"
        pid_file.write_text(str(os.getpid()))
        with patch.object(api, "launcher_environment") as preflight:
            result = api.do_command({"action": "run-scoped", "number": 42})
        self.assertFalse(result["ok"], result)
        preflight.assert_not_called()
        self.assertEqual(pid_file.read_text(), str(os.getpid()))
        self.assertFalse((run / "scoped_charter").exists())

    def test_concurrent_queue_and_scoped_requests_only_dispatch_one_pending_launcher(self):
        import subprocess
        from types import SimpleNamespace

        (self.runtime / "crewboss-launcher-gh.sh").write_text('exec sleep 30\n')
        entered = threading.Event()
        release = threading.Event()
        children = []

        def preflight(*args):
            entered.set()
            if not release.wait(3):
                raise RuntimeError("fixture preflight timeout")
            return dict(os.environ)

        def spawn(*args, **kwargs):
            child = subprocess.Popen(*args, **kwargs)
            children.append(child)
            return child

        dispatcher = SimpleNamespace(Popen=unittest.mock.Mock(side_effect=spawn), STDOUT=subprocess.STDOUT)
        try:
            with patch.object(api, "subprocess", dispatcher), patch.object(api, "launcher_environment", preflight):
                with ThreadPoolExecutor(max_workers=2) as pool:
                    queue = pool.submit(api.do_command, {"action": "run"})
                    self.assertTrue(entered.wait(2))
                    scoped = pool.submit(api.do_command, {"action": "run-scoped", "number": 42})
                    release.set()
                    self.assertTrue(queue.result(timeout=3)["ok"])
                    self.assertFalse(scoped.result(timeout=3)["ok"])
                dispatcher.Popen.assert_called_once()
                self.assertFalse((self.runtime / "run/launcher.pid").exists(), "API must not own launcher.pid")
                self.assertFalse((self.runtime / "run/scoped_charter").exists())
        finally:
            release.set()
            for child in children:
                child.kill()
                child.wait(timeout=3)

    def test_failed_scoped_spawn_releases_reservation_for_retry(self):
        from types import SimpleNamespace
        dispatcher = SimpleNamespace(Popen=unittest.mock.Mock(side_effect=OSError("fixture spawn failure")), STDOUT=-2)
        with patch.object(api, "subprocess", dispatcher):
            result = api.do_command({"action": "run-scoped", "number": 42})
        self.assertFalse(result["ok"], result)
        self.assertFalse((self.runtime / "run/scoped_charter").exists())
        self.assertFalse((self.runtime / "run/launcher.pid").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
