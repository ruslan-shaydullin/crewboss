#!/usr/bin/env bash
# agentconfig-fswork.test.sh — AgentConfigMap P1 (#356): fs.work capability → /work mount mode.
# Pure unit test (no nsjail): drives crewboss-spawn.sh's CB_SPAWN_DRYRUN hook, which prints the
# provisioning decision and exits before any jail/proxy/budget machinery. Locks that a role with
# fs_work:ro gets a read-only (-R) /work mount — the physical "analyst can't write the repo" barrier.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$HERE/../runtime/crewboss-spawn.sh"
MANIFEST_LIB="$HERE/../launcher/manifest.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
ko(){ fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

run_dryrun(){ # <role> <CB_FS_WORK or "unset">
  local role="$1" fsw="$2"
  if [ "$fsw" = "unset" ]; then
    CB_HOME="$ROOT/h" CB_SPAWN_DRYRUN=1 bash "$SPAWN" 5 "$role" /dev/null "$ROOT/w" 2>&1
  else
    CB_HOME="$ROOT/h" CB_SPAWN_DRYRUN=1 CB_FS_WORK="$fsw" bash "$SPAWN" 5 "$role" /dev/null "$ROOT/w" 2>&1
  fi
}

# 1. capability resolution: manifest_role_field reads fs_work from frontmatter
mkdir -p "$ROOT/m/roles"
printf -- '---\nname: x\nkind: analyst\ntools: Read, Bash\nprofile: analyst\nfs_work: ro\n---\nbody\n' \
  > "$ROOT/m/roles/x.md"
# shellcheck disable=SC1090
. "$MANIFEST_LIB" 2>/dev/null
v=$(manifest_role_field "$ROOT/m" x fs_work 2>/dev/null | tr -d '[:space:]')
[ "$v" = "ro" ] \
  && ok "manifest_role_field reads fs_work=ro from role frontmatter" \
  || ko "manifest_role_field returned '$v' (expected ro)"

# 2. provisioning decision: ro → read-only (-R), rw/unset → read-write (-B, back-compat)
echo "$(run_dryrun solution-analyst ro)" | grep -q "WORK_MOUNT=-R" \
  && ok "fs_work=ro → /work read-only mount (-R) — physical no-write barrier" \
  || ko "fs_work=ro did NOT yield -R: $(run_dryrun solution-analyst ro)"

echo "$(run_dryrun executor rw)" | grep -q "WORK_MOUNT=-B" \
  && ok "fs_work=rw → /work read-write mount (-B)" \
  || ko "fs_work=rw did NOT yield -B"

echo "$(run_dryrun executor unset)" | grep -q "WORK_MOUNT=-B" \
  && ok "fs_work unset → default -B (back-compat: non-migrated roles unchanged)" \
  || ko "fs_work unset did NOT default to -B"

# 3. the flag is actually wired into the real nsjail invocation (not only the dry-run)
grep -qF '$WORK_MOUNT "$WORK:/work"' "$SPAWN" \
  && ok "nsjail call uses \$WORK_MOUNT for /work (flag wired into real spawn)" \
  || ko "nsjail call does NOT use \$WORK_MOUNT — dry-run and real spawn diverge"

grep -qF -- '-B "$WORK:/work"' "$SPAWN" \
  && ko "old hardcoded '-B \$WORK:/work' still present (provision bypassed)" \
  || ok "old hardcoded '-B /work' removed (provision is the only path)"

# 4. analyst + reviewer migrated to fs_work: ro in the repo role library
for r in solution-analyst reviewer; do
  grep -qiE '^fs_work:[[:space:]]*ro' "$HERE/../../team-example/roles/$r.md" \
    && ok "$r migrated to fs_work: ro" \
    || ko "$r NOT migrated to fs_work: ro"
done

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
