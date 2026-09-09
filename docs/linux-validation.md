# Linux runtime validation

The `linux-runtime` CI job installs the built release as an unprivileged service
account on a disposable Ubuntu 24.04 x86_64 runner. It uses the shipped Python API,
board adapter, launcher, spawn primitive, seccomp policy and systemd templates.
GitHub and the model provider are local fixtures; this test makes no agent requests
and does not create issues or pull requests.

The test checks:

- authenticated API startup and restart after a process crash;
- saving and reading back a role through the installed API and team validator;
- Pause/Resume and Kill/Unkill behavior through HTTP;
- one launcher holding the actual `flock` lock;
- dispatch through real nsjail and delivery back to the board fixture;
- hidden host files, read-only system directories, a separate network namespace,
  blocked direct network access and a forbidden syscall killed by seccomp;
- launcher survival and idempotence across the keepalive oneshot's cgroup teardown.

Run only on a disposable Linux VM with systemd and passwordless sudo:

```sh
make setup
make release
bash tests/linux/install-nsjail.sh
sudo python3 tests/linux/integration.py \
  --bundle "dist/releases/crewboss-$(cat VERSION).tar.gz" \
  --report /tmp/crewboss-linux-runtime.json
```

The prerequisite script builds upstream [nsjail 3.6](https://github.com/google/nsjail/tree/f78475530b46d0186111a9096b30725f816b55fe)
from a pinned commit, including its pinned Kafel submodule. On Ubuntu's AppArmor
setup it allows user namespaces for that executable only. It leaves the installed
build dependencies, binary and AppArmor profile on the test host. The integration
test removes its own service units, account and temporary runtime after completion.

The current syscall policy is specific to x86_64. Doctor rejects other runtime
architectures before spawning work. The local dashboard/demo does not need Linux.
These fixture checks do not verify provider account access, live GitHub branch
protection, production credentials or a particular operator's network configuration.

The first alpha candidate passes all nine installed-runtime assertions in
[CI run 34364586695](https://github.com/ruslan-shaydullin/crewboss/actions/runs/34364586695).
Its report records the tested archive SHA-256; publication checks that value
against the release artifact from successful main CI.
