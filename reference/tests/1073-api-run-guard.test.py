#!/usr/bin/env python3
# 1073-api-run-guard.test.py — charter #1073, leaf #1095 (qa-engineer).
#
# Behavioural proof of root cause D: do_command action="run" (ui/server/crewboss-api.py)
# spawns the launcher via subprocess.Popen with NO singleton guard. The API already READS
# run/launcher.pid (os.kill(pid,0)) elsewhere; the run path must consult it too:
#
#   * with a LIVE run/launcher.pid  -> return "already running", do NOT call Popen.
#   * with a STALE/ABSENT pid       -> DO call Popen, and the launch env must preserve the
#                                      run-env contract (CB_HOME=$HOME/cbnet) so the loop it
#                                      starts targets the same run/launcher.lock (root A).
#
# Method: load do_command from crewboss-api.py via importlib.util; replace the module's
# `subprocess` with a shim whose .Popen is a recorder (real .run kept, so run-env.sh is
# still sourced). This is the ONLY accepted behavioural proof of root D.
#
# RED before the python fix: with a live pid, Popen IS called (no guard) -> RED.
# This file is NOT a *.test.sh: it carries NO per-leaf-manifest entry and is run via the
# acceptance `- check: python3 ...` line.
import importlib.util
import os
import shutil
import subprocess as _real_sub
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.path.normpath(os.path.join(HERE, "..", "..", "ui", "server", "crewboss-api.py"))
RUN_ENV_SRC = os.path.normpath(os.path.join(HERE, "..", "runtime", "run-env.sh"))

passed = 0
failed = 0
def ok(m):
    global passed; passed += 1; print("ok   " + m)
def ko(m):
    global failed; failed += 1; print("FAIL " + m)

# ── sandbox ───────────────────────────────────────────────────────────────────
TMP = tempfile.mkdtemp(prefix="cb1073-api-")
APIHOME = os.path.join(TMP, "apihome")          # module CB_HOME (where pid-file lives)
HOMEDIR = os.path.join(TMP, "home")             # hermetic $HOME -> run-env sets $HOME/cbnet
RUN = os.path.join(APIHOME, "run")
os.makedirs(RUN, exist_ok=True)
os.makedirs(os.path.join(HOMEDIR, "cbnet"), exist_ok=True)
shutil.copy(RUN_ENV_SRC, os.path.join(APIHOME, "run-env.sh"))
EXPECT_CBHOME = os.path.join(HOMEDIR, "cbnet")   # run-env.sh => CB_HOME=$HOME/cbnet

# Env BEFORE import (module reads CB_HOME/RUN at import time).
os.environ["CB_HOME"] = APIHOME
os.environ["CB_REPO"] = "test/repo"
os.environ["HOME"] = HOMEDIR
os.environ["CB_NO_INTEGRATE"] = "1"
os.environ.pop("CB_API_TOKEN", None)

spec = importlib.util.spec_from_file_location("crewboss_api_under_test", API)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
if not hasattr(m, "do_command"):
    ko("api module loaded but has no do_command")
    print("\npassed=%d failed=%d" % (passed, failed)); sys.exit(1)
ok("loaded do_command from crewboss-api.py via importlib.util")

# ── subprocess shim: real .run (run-env sourcing), recorder .Popen ────────────
class Recorder:
    def __init__(self): self.calls = []
    def __call__(self, *a, **kw):
        # consume/close any file objects passed as stdout/stderr to avoid fd leaks
        self.calls.append({"args": a, "kwargs": kw, "env": kw.get("env")})
        return None

class SubShim:
    def __init__(self, popen): self._popen = popen
    @property
    def Popen(self): return self._popen
    def __getattr__(self, k): return getattr(_real_sub, k)

def install_recorder():
    rec = Recorder()
    m.subprocess = SubShim(rec)
    return rec

def reset_run():
    for f in ("launcher.pid", "kill_switch"):
        p = os.path.join(RUN, f)
        if os.path.exists(p):
            os.remove(p)

# ── a guaranteed-dead pid (reaped) ────────────────────────────────────────────
_p = _real_sub.Popen(["true"]); _p.wait(); DEAD_PID = _p.pid

# =============================================================================
# Scenario 1: LIVE launcher.pid -> "already running", Popen NOT called
# =============================================================================
reset_run()
with open(os.path.join(RUN, "launcher.pid"), "w") as fh:
    fh.write(str(os.getpid()))     # this very process — guaranteed alive
rec = install_recorder()
res1 = m.do_command({"action": "run"})
msg1 = str((res1 or {}).get("msg", "")).lower()

if len(rec.calls) == 0:
    ok("live pid: subprocess.Popen was NOT called (singleton guard held)")
else:
    ko("live pid: subprocess.Popen WAS called %dx despite a live launcher.pid (root D: no run guard)" % len(rec.calls))

if "already" in msg1 and "run" in msg1:
    ok("live pid: do_command returned an 'already running' message (%r)" % (res1 or {}).get("msg"))
else:
    ko("live pid: expected an 'already running' message, got %r" % (res1 or {}).get("msg"))

# =============================================================================
# Scenario 2: STALE launcher.pid -> Popen IS called; run-env preserved
# =============================================================================
reset_run()
with open(os.path.join(RUN, "launcher.pid"), "w") as fh:
    fh.write(str(DEAD_PID))
rec = install_recorder()
res2 = m.do_command({"action": "run"})

if len(rec.calls) == 1:
    ok("stale pid: subprocess.Popen called exactly once (recovery start, not blocked)")
else:
    ko("stale pid: subprocess.Popen called %dx (expected exactly 1)" % len(rec.calls))

env2 = (rec.calls[0]["env"] if rec.calls else None) or {}
if env2.get("CB_HOME") == EXPECT_CBHOME:
    ok("stale pid: launch env preserves run-env contract CB_HOME=%s ($HOME/cbnet, root A)" % EXPECT_CBHOME)
else:
    ko("stale pid: launch env CB_HOME=%r != expected %r (run-env contract not preserved)" % (env2.get("CB_HOME"), EXPECT_CBHOME))

# =============================================================================
# Scenario 3: ABSENT launcher.pid -> Popen IS called
# =============================================================================
reset_run()
rec = install_recorder()
res3 = m.do_command({"action": "run"})
if len(rec.calls) == 1:
    ok("absent pid: subprocess.Popen called exactly once (cold start)")
else:
    ko("absent pid: subprocess.Popen called %dx (expected exactly 1)" % len(rec.calls))

# ── teardown ──
shutil.rmtree(TMP, ignore_errors=True)
print("\npassed=%d failed=%d" % (passed, failed))
sys.exit(0 if failed == 0 else 1)
