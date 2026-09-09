#!/usr/bin/env python3
"""Source-backed offline regressions for #1341 and #1346."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "reference/runtime"


class LauncherHonestyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cb-honesty-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        (self.home / "bin").mkdir()
        (self.home / "run/state").mkdir(parents=True)
        (self.home / "board-gh.sh").write_bytes((ROOT / "reference/runtime/board-gh.sh").read_bytes())
        (self.home / "launchable.sh").write_bytes((ROOT / "reference/launcher/launchable.sh").read_bytes())
        self.issues = self.home / "issues.json"
        self.issues.write_text(json.dumps({
            "1": self.issue(1, ["type:charter", "status:approved"]),
            "2": self.issue(2, ["type:charter", "status:approved"]),
            "10": self.issue(10, ["type:agent", "status:review", "role:reviewer"], "Charter: #1"),
            "11": self.issue(11, ["type:agent", "status:blocked", "role:qa-engineer"], "Charter: #1"),
            "20": self.issue(20, ["type:agent", "role:executor"], "Charter: #2\n## Acceptance (machine)\n- check: true"),
        }))
        stub = self.home / "bin/gh"
        stub.write_text("#!/usr/bin/env python3\n" + GH_STUB)
        stub.chmod(0o755)
        self.env = {"PATH": str(self.home / "bin") + os.pathsep + os.environ["PATH"],
                    "HOME": str(self.home), "CB_HOME": str(self.home), "CB_REPO": "test/repo",
                    "TEST_ISSUES": str(self.issues), "TEST_LOG": str(self.home / "gh.log"),
                    "RUNTIME": str(RUNTIME), "BOARD_SRC": str(ROOT / "reference/runtime/board-gh.sh")}

    @staticmethod
    def issue(n, labels, body=""):
        return {"number": n, "state": "OPEN", "labels": [{"name": x} for x in labels],
                "body": body, "comments": [], "title": f"Fixture {n}"}

    def run_shell(self, code, **env):
        prelude = 'set -uo pipefail; RUN="$CB_HOME/run"; STATE="$RUN/state"; HERE_LAUNCHER="$RUNTIME"; BOARD="$BOARD_SRC"; source "$RUNTIME/launcher-board.sh" || exit $?; '
        return subprocess.run(["bash", "-c", prelude + code], env={**self.env, **env},
                              text=True, capture_output=True, timeout=20)

    def read(self):
        return json.loads(self.issues.read_text())

    def labels(self, n):
        return [x["name"] for x in self.read()[str(n)]["labels"]]

    def verdict(self, text):
        data = self.read()
        data["10"]["comments"] = [{"body": text}]
        self.issues.write_text(json.dumps(data))

    def triage_contract_fixture(self):
        # Exercise the production prep argument validator and role catalog. The
        # fixture doctor stops after preflight entry, before git/GitHub/nsjail.
        for name in ("crewboss-prep-spawn-gh.sh", "run-env.sh"):
            (self.home / name).write_bytes((RUNTIME / name).read_bytes())
        catalog = self.home / "gov/.claude/agents"
        catalog.mkdir(parents=True)
        for role, source in (("executor", "reference/.claude/agents/executor.md"),
                             ("triage", "team-example/roles/triage.md")):
            (catalog / f"{role}.md").write_bytes((ROOT / source).read_bytes())
        doctor = self.home / "crewboss-doctor.sh"
        doctor.write_text('#!/bin/sh\nprintf "%s" "$*" > "$CB_HOME/triage-preflight"\nexit 73\n')
        flock = self.home / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n"); flock.chmod(0o755)
        triage = self.home / "bin/triage"
        triage.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ["CB_HOME"])
with (home / "triage-args.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
# Stop the real loop on its next tick, after the dispatch under test.
(home / "run/kill_switch").touch()
os.execvp("bash", ["bash", str(home / "crewboss-prep-spawn-gh.sh"), *sys.argv[1:]])
''')
        triage.chmod(0o755)
        return {"CB_ENV_FILE": "/dev/null", "CB_NO_INTEGRATE": "1",
                "CB_TRIAGE_SPAWN": str(triage), "CB_RETRY_CAP": "1",
                "CB_MAX_PARALLEL": "1", "CB_MAX_TICKS": "4", "CB_POLL": "1",
                "CB_RL_FLOOR": "0", "CB_RL_FLOOR_GQL": "0",
                "CB_TRIAGE_BACKOFF": "0", "CB_TRIAGE_MIN_LIFETIME": "3600"}

    def assert_triage_contract(self):
        calls = [json.loads(line) for line in (self.home / "triage-args.jsonl").read_text().splitlines()]
        self.assertEqual(calls, [["20", "triage"]])
        self.assertEqual((self.home / "triage-preflight").read_text(), "--preflight")
        self.assertEqual((self.home / "run/state/20/kind").read_text(), "triage")
        self.assertIn("status:needs-triage", self.labels(20))
        self.assertFalse((self.home / "run/state/20/term").exists())

    def test_route_passes_triage_role_to_real_prep(self):
        result = self.run_shell(
            'source "$RUNTIME/crewboss-launcher-gh.sh"; route 20 2; rc=$?; wait; exit "$rc"',
            **self.triage_contract_fixture(),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_triage_contract()

    def test_real_run_executor_failure_passes_triage_role_to_real_prep(self):
        env = self.triage_contract_fixture()
        executor = self.home / "bin/executor"
        executor.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
home = Path(os.environ["CB_HOME"])
(home / "executor-args.json").write_text(json.dumps(sys.argv[1:]))
work = home / "run/work" / sys.argv[1]
work.mkdir(parents=True, exist_ok=True)
(work / "status.json").write_text('{"phase":"failed"}')
sys.exit(2)
''')
        executor.chmod(0o755)
        result = self.run_shell('source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_run',
                                **env, CB_SPAWN=str(executor))
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.home / "executor-args.json").read_text()), ["20", "executor"])
        self.assertIn("#20 failed(1) -> needs-triage", result.stdout)
        self.assert_triage_contract()

    def test_real_run_triage_crash_retry_passes_role_to_real_prep(self):
        env = self.triage_contract_fixture()
        data = self.read()
        data["20"]["labels"].append({"name": "status:needs-triage"})
        self.issues.write_text(json.dumps(data))
        state = self.home / "run/state/20"; state.mkdir()
        (state / "pid").write_text("99999999")
        (state / "kind").write_text("triage")
        (state / "triage_spawn_ts").write_text(str(int(time.time())))
        work = self.home / "run/work/20"; work.mkdir(parents=True)
        (work / "status.json").write_text('{"phase":"failed"}')
        result = self.run_shell('source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_run', **env)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn("kind=triage: crash-death", result.stdout)
        self.assertEqual((state / "triage_n").read_text(), "1")
        self.assertFalse((state / "triage_done").exists())
        self.assert_triage_contract()

    def test_real_loop_read_failure_never_exits_as_successful_idle(self):
        # The source entrypoint executes the real run loop; flock is outside this
        # test's scope and is a no-op fixture on hosts without Linux util-linux.
        flock = self.home / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n"); flock.chmod(0o755)
        result = self.run_shell(
            'source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_run',
            CB_ENV_FILE="/dev/null", CB_NO_INTEGRATE="1", CB_MAX_TICKS="2",
            CB_POLL="0", CB_INFRA_BACKOFF="0", CB_RL_FLOOR="0", CB_RL_FLOOR_GQL="0",
            TEST_READ_ERROR="403",
        )
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertNotIn("idle — run complete", result.stdout)
        self.assertFalse((self.home / "gh.log").exists())

    def test_real_review_completion_failed_label_read_preserves_attempts(self):
        flock = self.home / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n"); flock.chmod(0o755)
        state = self.home / "run/state/1"
        state.mkdir()
        (state / "pid").write_text("99999999")
        (state / "kind").write_text("plan-review")
        (state / "tries").write_text("0")
        result = self.run_shell(
            'source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_run',
            CB_ENV_FILE="/dev/null", CB_NO_INTEGRATE="1", CB_MAX_TICKS="2",
            CB_POLL="0", CB_INFRA_BACKOFF="0", CB_RL_FLOOR="0", CB_RL_FLOOR_GQL="0",
            TEST_VIEW_ERROR="503",
        )
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertEqual((state / "tries").read_text(), "0")
        self.assertFalse((state / "term").exists())
        self.assertNotIn("plan-review failed", result.stdout)

    def test_real_integrator_consumes_delivery_before_no_pr_stale_watchdog(self):
        self.verdict("## Review (machine)\nverdict: approve")
        result = self.run_shell(
            'source "$RUNTIME/crewboss-launcher-gh.sh"; '
            'for tick in {1..12}; do _integrator_cycle || exit $?; done',
            CB_ENV_FILE="/dev/null", CB_NO_INTEGRATE="1", CB_REVIEW_STALE_TICKS="1",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read()["10"]["state"], "CLOSED")
        self.assertNotIn("status:blocked", self.labels(10))
        self.assertFalse((self.home / "run/state/10/stale_ticks").exists())

    def test_malformed_json_is_infrastructure_failure_before_business_verdict(self):
        result = self.run_shell(
            'source "$RUNTIME/crewboss-launcher-gh.sh"; GIT_REMOTE=fixture; _recovery_reverify 11',
            CB_ENV_FILE="/dev/null", CB_NO_INTEGRATE="1", TEST_READ_ERROR="object",
        )
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertNotIn("RED:", result.stdout)
        self.assertTrue((self.home / "run/infra-failure").exists())

    def test_failed_read_prevents_subsequent_spawn(self):
        result = self.run_shell(
            'gh issue view 11 --json labels >/dev/null; _cb_spawn sh -c "echo forbidden"',
            TEST_READ_ERROR="503",
        )
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertNotIn("forbidden", result.stdout)

    def test_latest_reviewer_correction_replaces_malformed_delivery(self):
        self.verdict("## Review (machine)\nverdict: unknown")
        data = self.read()
        data["10"]["comments"].append({"body": "## Review (machine)\nverdict: approve"})
        self.issues.write_text(json.dumps(data))
        result = self.run_shell('_cb_reviewer_consume 10')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read()["10"]["state"], "CLOSED")

    def test_real_completion_attempt_is_not_burned_by_retrying_delivery(self):
        result = self.run_shell(
            '_cb_state_set 11 starttime first; '
            'a=$(_cb_completion_attempt 11); b=$(_cb_completion_attempt 11); '
            '[ "$a" = 1 ] && [ "$b" = 1 ] || exit 2; '
            '_cb_state_set 11 starttime second; [ "$(_cb_completion_attempt 11)" = 2 ]'
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_role_getter_handles_multiple_labels(self):
        result = subprocess.run(["bash", str(ROOT / "reference/runtime/board-gh.sh"), "get", "11", "role"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "qa-engineer")

    def test_board_read_error_and_empty_payload_are_not_business_values(self):
        for failure in ("403", "503", "empty", "object"):
            with self.subTest(failure=failure):
                result = subprocess.run(["bash", str(ROOT / "reference/runtime/board-gh.sh"), "get", "11", "state"],
                                        env={**self.env, "TEST_READ_ERROR": failure}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_label_read_has_third_failure_state_and_does_not_consume_attempt(self):
        for failure in ("403", "503", "empty", "object"):
            with self.subTest(failure=failure):
                result = self.run_shell('_cb_has_label 1 plan:agreed', TEST_READ_ERROR=failure)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse((self.home / "run/state/1/tries").exists())

    def test_failed_label_write_cannot_commit_terminal_state(self):
        result = self.run_shell('_cb_finish_leaf 10 blocked "test reason"', TEST_WRITE_ERROR="503")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / "run/state/10/term").exists())
        self.assertIn("status:review", self.labels(10))
        result = self.run_shell('_cb_clear_infra; _cb_finish_leaf 10 blocked "test reason"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / "run/state/10/term").read_text(), "1")

    def test_reconciliation_repairs_completed_in_progress_leaf(self):
        data = self.read()
        data["11"]["labels"] = [{"name": x} for x in ["type:agent", "role:qa-engineer", "status:in-progress"]]
        self.issues.write_text(json.dumps(data))
        work = self.home / "run/work/11"
        work.mkdir(parents=True)
        (work / "status.json").write_text('{"phase":"done"}')
        state = self.home / "run/state/11"
        state.mkdir()
        (state / "term").write_text("1")
        result = self.run_shell('_cb_reconcile_state')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("status:review", self.labels(11))
        self.assertNotIn("status:in-progress", self.labels(11))

    def test_reconciliation_preserves_completed_charter_plan_review(self):
        data = self.read()
        data["1"]["labels"] = [{"name": x} for x in ["type:charter", "status:plan-review"]]
        self.issues.write_text(json.dumps(data))
        state = self.home / "run/state/1"; state.mkdir()
        (state / "term").write_text("1")
        (state / "kind").write_text("charter")
        work = self.home / "run/work/1"; work.mkdir(parents=True)
        (work / "status.json").write_text('{"phase":"done"}')
        result = self.run_shell('_cb_reconcile_state')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("status:review", self.labels(1))
        self.assertIn("status:plan-review", self.labels(1))
        self.assertEqual((state / "term").read_text(), "1")
        (state / "pid").write_text("99999999")
        result = self.run_shell('source "$RUNTIME/crewboss-launcher-gh.sh"; reconcile',
                                CB_ENV_FILE="/dev/null", CB_NO_INTEGRATE="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("status:review", self.labels(1))
        self.assertEqual((state / "pid").read_text(), "99999999")

    def test_once_failed_invocation_can_retry_and_really_spawn(self):
        flock = self.home / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n"); flock.chmod(0o755)
        catalog = self.home / "gov/.claude/agents"; catalog.mkdir(parents=True)
        (catalog / "executor.md").write_text("Fixture executor")
        spawn = self.home / "bin/spawn"
        spawn.write_text('#!/bin/sh\nprintf "%s %s" "$1" "$2" > "$CB_HOME/spawned"\n')
        spawn.chmod(0o755)
        env = {"CB_ENV_FILE": "/dev/null", "CB_NO_INTEGRATE": "1", "CB_SPAWN": str(spawn)}
        command = 'source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_once'
        first = self.run_shell(command, **env, TEST_READ_ERROR="503")
        self.assertEqual(first.returncode, 75, first.stdout + first.stderr)
        self.assertNotIn("cycle done", first.stdout)
        self.assertFalse((self.home / "spawned").exists())
        second = self.run_shell(command, **env)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual((self.home / "spawned").read_text(), "20 executor")
        self.assertIn("status:review", self.labels(20))

    def test_reconcile_failed_invocation_can_retry_delivery(self):
        flock = self.home / "bin/flock"
        flock.write_text("#!/bin/sh\nexit 0\n"); flock.chmod(0o755)
        data = self.read()
        data["11"]["labels"] = [{"name": x} for x in ["type:agent", "status:in-progress"]]
        self.issues.write_text(json.dumps(data))
        state = self.home / "run/state/11"; state.mkdir()
        (state / "term").write_text("1")
        work = self.home / "run/work/11"; work.mkdir(parents=True)
        (work / "status.json").write_text('{"phase":"done"}')
        command = 'source "$RUNTIME/crewboss-launcher-gh.sh"; cmd_reconcile'
        env = {"CB_ENV_FILE": "/dev/null", "CB_NO_INTEGRATE": "1"}
        first = self.run_shell(command, **env, TEST_READ_ERROR="503")
        self.assertEqual(first.returncode, 75, first.stdout + first.stderr)
        second = self.run_shell(command, **env)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("status:review", self.labels(11))

    def test_review_approve_closes_without_a_pull_request(self):
        self.verdict("## Review (machine)\nverdict: approve\nreason: checked the implementation")
        result = self.run_shell('_cb_reviewer_consume 10')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()["10"]["state"], "CLOSED")
        self.assertFalse((self.home / "run/state/10/stale_ticks").exists())

    def test_review_blocked_reworks_owning_qa_role_and_closes_reviewer(self):
        self.verdict("## Review (machine)\nverdict: blocked\ntarget: #11\nreason: missing regression test")
        result = self.run_shell('_cb_reviewer_consume 10')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()["10"]["state"], "CLOSED")
        self.assertIn("status:needs-rework", self.labels(11))
        self.assertIn("role:qa-engineer", self.labels(11))
        self.assertNotIn("status:blocked", self.labels(11))

    def test_blocked_review_reopens_a_completed_leaf_before_rework(self):
        self.verdict("## Review (machine)\nverdict: blocked\ntarget: #11\nreason: regression")
        data = self.read(); data["11"]["state"] = "CLOSED"; self.issues.write_text(json.dumps(data))
        result = self.run_shell('_cb_reviewer_consume 10')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.read()["11"]["state"], "OPEN")
        self.assertEqual(self.read()["10"]["state"], "CLOSED")
        self.assertIn("status:needs-rework", self.labels(11))
        self.assertIn("role:qa-engineer", self.labels(11))
        calls = [json.loads(line) for line in (self.home / "gh.log").read_text().splitlines()]
        reopen = next(i for i, c in enumerate(calls) if c[:3] == ["issue", "reopen", "11"])
        route = next(i for i, c in enumerate(calls) if c[:3] == ["issue", "edit", "11"])
        close = next(i for i, c in enumerate(calls) if c[:3] == ["issue", "close", "10"])
        self.assertLess(reopen, route)
        self.assertLess(route, close)

    def test_failed_reopen_cannot_complete_reviewer_or_label_closed_target(self):
        self.verdict("## Review (machine)\nverdict: blocked\ntarget: #11\nreason: regression")
        data = self.read(); data["11"]["state"] = "CLOSED"; self.issues.write_text(json.dumps(data))
        result = self.run_shell('_cb_reviewer_consume 10', TEST_REOPEN_ERROR="503")
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertEqual(self.read()["11"]["state"], "CLOSED")
        self.assertEqual(self.read()["10"]["state"], "OPEN")
        self.assertNotIn("status:needs-rework", self.labels(11))
        self.assertFalse((self.home / "run/state/10/term").exists())

    def test_review_cannot_rework_an_unrelated_charter(self):
        self.verdict("## Review (machine)\nverdict: blocked\ntarget: #20\nreason: unrelated")
        result = self.run_shell('_cb_reviewer_consume 10')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read()["10"]["state"], "OPEN")
        self.assertNotIn("status:needs-rework", self.labels(20))

    def test_review_write_failure_keeps_delivery_retryable(self):
        self.verdict("## Review (machine)\nverdict: approve")
        result = self.run_shell('_cb_reviewer_consume 10', TEST_WRITE_ERROR="503")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read()["10"]["state"], "OPEN")
        self.assertFalse((self.home / "run/state/10/term").exists())

    def test_blocked_head_parks_and_preserves_next_runnable_charter(self):
        queue = self.home / "run/queue.json"
        queue.write_text('{"order":[1,2],"extra":"preserve"}')
        data = self.read()
        data["10"]["state"] = "CLOSED"
        self.issues.write_text(json.dumps(data))
        result = self.run_shell('_cb_queue_park', CB_QUEUE_BLOCKED_TICKS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hold", self.labels(1))
        self.assertEqual(json.loads(queue.read_text()), {"order": [2], "extra": "preserve"})
        self.assertIn("#11", self.read()["1"]["comments"][-1]["body"])

    def test_blocked_history_does_not_park_a_charter_with_live_manager(self):
        queue = self.home / "run/queue.json"; queue.write_text('{"order":[1,2]}')
        data = self.read(); data["10"]["state"] = "CLOSED"; self.issues.write_text(json.dumps(data))
        state = self.home / "run/state/1"; state.mkdir()
        (state / "pid").write_text(str(os.getpid()))
        (state / "kind").write_text("analysis")
        result = self.run_shell('_cb_queue_park', CB_QUEUE_BLOCKED_TICKS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(queue.read_text())["order"], [1, 2])
        self.assertNotIn("hold", self.labels(1))

    def test_blocked_history_does_not_park_upstream_or_manual_charter_stages(self):
        queue = self.home / "run/queue.json"
        for stage in ("needs-plan", "needs-analysis", "plan-review", "team-review", "acceptance-review", "review"):
            with self.subTest(stage=stage):
                queue.write_text('{"order":[1,2]}')
                data = self.read(); data["10"]["state"] = "CLOSED"
                data["1"]["labels"] = [{"name": x} for x in ["type:charter", "status:approved", "status:"+stage]]
                self.issues.write_text(json.dumps(data))
                result = self.run_shell('_cb_queue_park', CB_QUEUE_BLOCKED_TICKS="1")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(queue.read_text())["order"], [1, 2])
                self.assertNotIn("hold", self.labels(1))

    def test_blocked_head_write_failure_preserves_queue(self):
        queue = self.home / "run/queue.json"
        queue.write_text('{"order":[1,2]}')
        data = self.read(); data["10"]["state"] = "CLOSED"; self.issues.write_text(json.dumps(data))
        result = self.run_shell('_cb_queue_park', CB_QUEUE_BLOCKED_TICKS="1", TEST_WRITE_ERROR="503")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(queue.read_text())["order"], [1, 2])


GH_STUB = r'''import json, os, sys
from pathlib import Path
args=sys.argv[1:]; command=tuple(args[:2]); path=Path(os.environ["TEST_ISSUES"])
read=command in (("issue","view"),("issue","list"),("pr","list"),("pr","view")) or (args and args[0]=="api")
failure=os.environ.get("TEST_READ_ERROR") or (os.environ.get("TEST_VIEW_ERROR") if command==("issue","view") else None)
if read and failure:
    if failure=="object": print('{"message":"API failure"}'); sys.exit(0)
    if failure=="empty": sys.exit(0)
    print("HTTP "+failure, file=sys.stderr); sys.exit(1)
data=json.loads(path.read_text())
if command==("issue","view"):
    print(json.dumps(data[args[2]])); sys.exit(0)
if command==("issue","list") or (args and args[0]=="api"):
    print(json.dumps(list(data.values()))); sys.exit(0)
if command==("pr","list"): print("[]"); sys.exit(0)
if command==("label","create"): sys.exit(0)
with Path(os.environ["TEST_LOG"]).open("a") as log: log.write(json.dumps(args)+"\n")
if os.environ.get("TEST_WRITE_ERROR") or (command==("issue","reopen") and os.environ.get("TEST_REOPEN_ERROR")):
    print("HTTP fixture write failure",file=sys.stderr); sys.exit(1)
issue=data[args[2]]
if command==("issue","edit"):
    names=[x["name"] for x in issue["labels"]]
    for i,arg in enumerate(args):
        if arg=="--remove-label": names=[x for x in names if x!=args[i+1]]
        if arg=="--add-label" and args[i+1] not in names: names.append(args[i+1])
    issue["labels"]=[{"name":x} for x in names]
elif command==("issue","close"): issue["state"]="CLOSED"
elif command==("issue","reopen"): issue["state"]="OPEN"
elif command==("issue","comment"):
    flag="--body" if "--body" in args else "-b"
    issue["comments"].append({"body":args[args.index(flag)+1]})
else: print("unhandled gh "+str(args),file=sys.stderr); sys.exit(2)
path.write_text(json.dumps(data))
'''

if __name__ == "__main__":
    unittest.main(verbosity=2)
