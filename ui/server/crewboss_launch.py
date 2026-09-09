"""Build and validate the shared launcher configuration before starting work."""
import os
from pathlib import Path
import subprocess
import threading


def reap_launcher(process, on_exit=None):
    """Reap this API-owned child promptly without blocking an HTTP request.

    Popen's opportunistic cleanup only runs on later process creation. Keeping
    one wait thread per launcher prevents exited children from remaining zombies
    and satisfying the PID-based running guard indefinitely.
    """
    def wait():
        try:
            process.wait()
        finally:
            if on_exit is not None:
                on_exit()

    reaper = threading.Thread(target=wait, name=f"launcher-reaper-{process.pid}", daemon=True)
    reaper.start()
    return reaper


def load_runtime_environment(runtime_home, repository):
    seed = dict(os.environ)
    seed.setdefault("HOME", os.path.expanduser("~"))
    seed.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin")
    seed["CB_HOME"] = runtime_home
    seed["CB_REPO"] = repository
    config = Path(runtime_home) / "run-env.sh"
    if not config.is_file():
        raise RuntimeError("Launcher configuration is missing: deploy run-env.sh first")
    try:
        result = subprocess.run(
            ["bash", "-c", 'set -a; source "$1" >&2 || exit $?; set +a; env -0',
             "crewboss-api", str(config)],
            env=seed, capture_output=True, timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("Could not load launcher configuration") from error
    if result.returncode:
        # Trusted shell configuration may print credentials; do not return its
        # output over HTTP. The failed stage is enough to locate the setup error.
        raise RuntimeError("Launcher configuration failed; check CB_ENV_FILE and run-env.sh")
    environment = {}
    for item in result.stdout.split(b"\0"):
        if b"=" in item:
            key, value = item.split(b"=", 1)
            environment[os.fsdecode(key)] = os.fsdecode(value)
    if environment.get("CB_HOME") != runtime_home or environment.get("CB_REPO") != repository:
        raise RuntimeError("Launcher configuration differs from this API; restart the API after changing it")
    return environment


def launcher_environment(runtime_home, repository):
    environment = load_runtime_environment(runtime_home, repository)
    doctor = Path(runtime_home) / "crewboss-doctor.sh"
    if not doctor.is_file():
        raise RuntimeError("Runtime preflight is missing: deploy crewboss-doctor.sh first")
    try:
        result = subprocess.run(
            ["bash", str(doctor), "--preflight"], env=environment,
            capture_output=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("Runtime preflight could not complete") from error
    if result.returncode:
        raise RuntimeError("Runtime preflight failed; run crewboss-doctor.sh --preflight on the host")
    return environment
