# Round 3c — seccomp (Kafel allowlist) — validated 2026-06-10

The "third nail" of the jail: namespaces (FS, Round 3a) + network (Round 3b) +
**syscall filter**. Without it nsjail holds only namespaces+rlimits and the kernel
attack surface is open. nsjail applies NO seccomp by default — you must pass a policy.

## Result
- `claude.kafel` — default-deny allowlist (`DEFAULT KILL_PROCESS`), 168 syscalls by
  name + 5 by number.
- claude smoke (`OK`) and full `git clone+push` to github run **under the filter**.
- 23 dangerous syscalls confirmed **killed** (SIGSYS): ptrace, mount, umount2, unshare,
  setns, chroot, pivot_root, init_module, finit_module, delete_module(absent⇒killed),
  kexec_load, bpf, perf_event_open, add_key, keyctl, request_key, reboot, swapon,
  settimeofday, clock_settime, syslog, process_vm_readv, setuid, setgid.
- Allowed-syscall sanity (getpid) passes through. So the filter is real, not all-kill.

## How the allowlist was built (reproducible)
1. `run-sc-discover3.sh` — run the FULL in-jail payload (bash + python bridge + claude,
   and bash + git/gh) under `strace -f -c -U name`, union the syscall name sets.
   → `sc-claude.list`, `sc-git.list`, `sc-union.list` (111 names).
2. `gen-names.sh` — union + a generous benign "essentials" buffer (exit/exit_group,
   signal variants, libc variants like faccessat2/renameat2, git ops copy_file_range/
   sendfile) **minus** anything dangerous (clock_settime/settimeofday stripped). → 173.
3. `find-unknown.sh` — detect names this kafel build can't compile (parse error
   "Undefined identifier"). → 5 unknown.
4. `run-sc-policy2.sh` — emit `claude.kafel`, test-parse on /bin/true, then run claude +
   git under it; `probe.sh`/`run-probe.sh` verify the dangerous set is killed.

## Grables (cost iterations)
- **`strace -c` under-reports `exit_group`/`exit`** — absent from the histogram though
  every process calls one. Must be added by hand or the process dies on exit under KILL.
- **kafel's amd64 table is incomplete:** `stat`(4), `fstat`(5), `lstat`(6), `sendfile`(40),
  `uname`(63) are **not** in this build's name table (it has fstatfs/fsync/ftruncate but
  not fstat). git/Bun call them constantly. Fix: numeric form `SYSCALL[<nr>]` (uppercase
  keyword; lowercase `syscall[5]` and bare `5` both fail to parse).
- **strace as pidns-init hangs:** `nsjail ... -- bash -c 'exec strace ... claude'` makes
  strace PID 1 of the pid-ns and it never writes its `-c` report / never exits. Run strace
  as a normal child (`bash -c 'strace ... ; ...'`), not via `exec`.
- The discovered surface is for the **smoke slice** (claude reply + git push). A fuller
  executor (file edits, `npm`/vitest, node build) will hit more syscalls — re-run discovery
  on the real workload before locking KILL in production, or keep the essentials buffer wide.

## Use
```
nsjail ... --seccomp_policy /path/to/claude.kafel --seccomp_log -- <cmd>
```
`--seccomp_log` adds audit logging of kills (read via sudo dmesg / auditd) — keep it on in
prod for forensics; the action stays KILL_PROCESS.
