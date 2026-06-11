#!/usr/bin/env bash
# Build kafel allowlist from a union list + benign essentials.
# Names kafel's amd64 table doesn't know are auto-mapped to SYSCALL[nr] via ausyscall.
# $1 = union list file (default sc-r4union.list); $2 = output policy (default claude.kafel)
set -u
UNION="${1:-/tmp/cbnet/sc-r4union.list}"
OUT="${2:-/tmp/cbnet/claude.kafel}"
ESS="exit exit_group rt_sigtimedwait rt_sigpending rt_sigqueueinfo rt_tgsigqueueinfo \
waitid pipe2 dup3 accept epoll_create signalfd signalfd4 memfd_create eventfd \
faccessat faccessat2 lstat fstatfs getdents mremap gettimeofday clock_getres time \
umask utimensat utime fchmod fchmodat renameat renameat2 copy_file_range sendfile \
splice tee getrlimit getrusage capget pwrite64 pwritev writev readv preadv fadvise64 \
sched_getparam sched_get_priority_max sched_get_priority_min sched_getscheduler \
getpriority setpriority flock fallocate truncate sync_file_range fchdir getsid \
getpgid setpgid get_robust_list membarrier sched_getattr sched_setattr pause \
fstat stat uname"
# DANGEROUS - never allow (stripped even if discovered)
DENY='clock_settime|settimeofday|ptrace|mount|umount2|unshare|setns|chroot|pivot_root|init_module|finit_module|delete_module|kexec_load|bpf|perf_event_open|add_key|keyctl|request_key|reboot|swapon|swapoff|process_vm_readv|process_vm_writev|setuid|setgid|setreuid|setregid|setresuid|setresgid|setfsuid|setfsgid|capset|acct|syslog'

ALL=$( { cat "$UNION"; echo "$ESS" | tr ' ' '\n'; } | grep -E '^[a-z][a-z0-9_]+$' | grep -vxE "$DENY" | sort -u )
known=(); numeric=(); unmapped=()
for s in $ALL; do
  printf 'ALLOW { %s }\nDEFAULT KILL_PROCESS\n' "$s" > /tmp/cbnet/_t.kafel
  if /usr/local/bin/nsjail -Mo --disable_clone_newnet --really_quiet \
       -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc \
       --seccomp_policy /tmp/cbnet/_t.kafel -- /bin/true 2>&1 | grep -q "Couldn't prepare"; then
    nr=$(ausyscall --exact "$s" 2>/dev/null)
    if [[ "$nr" =~ ^[0-9]+$ ]]; then numeric+=("SYSCALL[$nr]"); else unmapped+=("$s"); fi
  else
    known+=("$s")
  fi
done
{ echo "ALLOW {"; ( IFS=,; echo "${known[*]},${numeric[*]}" ); echo "}"; echo "DEFAULT KILL_PROCESS"; } > "$OUT"
echo "policy: known=${#known[@]} numeric=${#numeric[@]} (${numeric[*]}) unmapped=${#unmapped[@]}: ${unmapped[*]}"
echo "-> $OUT ($(wc -c < "$OUT") bytes)"
# verify the whole thing parses
/usr/local/bin/nsjail -Mo --disable_clone_newnet --really_quiet \
  -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc --seccomp_policy "$OUT" -- /bin/true 2>&1 \
  | grep -q "Couldn't prepare" && { echo "FINAL PARSE FAIL"; exit 1; } || echo "FINAL PARSE OK"
