#!/usr/bin/env bash
# Probe: each forbidden syscall should be KILLed by seccomp (SIGSYS -> rc 159).
# python3 runs fine under the policy (it's the bridge runtime), so a kill here
# is caused by the explicit forbidden syscall, not by python startup.
declare -A NR=( [ptrace]=101 [mount]=165 [umount2]=166 [unshare]=272 [setns]=308 \
  [chroot]=161 [pivot_root]=155 [init_module]=175 [finit_module]=313 [kexec_load]=246 \
  [bpf]=321 [perf_event_open]=298 [add_key]=248 [keyctl]=250 [request_key]=249 \
  [reboot]=169 [swapon]=167 [clock_settime]=227 [settimeofday]=164 [syslog]=103 \
  [process_vm_readv]=310 [setuid]=105 [setgid]=106 )
for name in "${!NR[@]}"; do
  python3 -c "import ctypes; ctypes.CDLL(None).syscall(${NR[$name]},0,0,0,0,0,0)" 2>/dev/null
  rc=$?
  if [ $rc -eq 159 ] || [ $rc -eq 137 ]; then echo "BLOCKED   $name"
  else echo "REACHABLE $name (rc=$rc)  <-- LEAK"; fi
done
