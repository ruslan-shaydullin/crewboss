#!/usr/bin/env bash
# A name is UNKNOWN to kafel iff policy parse fails ("Couldn't prepare sandboxing policy").
# /bin/true being killed at runtime (single-syscall allow) is irrelevant - that's post-parse.
mapfile -t NAMES < /tmp/cbnet/policy-names.txt
unknown=()
for s in "${NAMES[@]}"; do
  printf 'ALLOW { %s }\nDEFAULT KILL_PROCESS\n' "$s" > /tmp/cbnet/t.kafel
  out=$(/usr/local/bin/nsjail -Mo --disable_clone_newnet --really_quiet \
        -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc \
        --seccomp_policy /tmp/cbnet/t.kafel -- /bin/true 2>&1)
  echo "$out" | grep -q "Couldn't prepare sandboxing policy" && unknown+=("$s")
done
echo "UNKNOWN (${#unknown[@]}): ${unknown[*]}"
