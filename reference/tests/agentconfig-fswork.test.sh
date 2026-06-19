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

# 5. FAIL-SAFE: a typo'd/unknown fs_work value locks down (-R), never silently opens (default-deny)
echo "$(run_dryrun executor garbage)" | grep -q "WORK_MOUNT=-R" \
  && ok "fs_work=<unknown> → fail-closed -R (default-deny, no silent open on typo)" \
  || ko "fs_work=<unknown> did NOT fail-closed to -R: $(run_dryrun executor garbage)"

# 6. fs.cbnet capability → /cbnet (runtime: scripts/manifest/state) mount mode
dry_cbnet(){ CB_HOME="$ROOT/h" CB_SPAWN_DRYRUN=1 CB_FS_CBNET="$1" bash "$SPAWN" 5 solution-analyst /dev/null "$ROOT/w" 2>&1; }
echo "$(dry_cbnet ro)" | grep -q "CBNET_MOUNT=-R" \
  && ok "fs_cbnet=ro → /cbnet read-only (-R) — can't write runtime/manifest" \
  || ko "fs_cbnet=ro did NOT yield CBNET_MOUNT=-R: $(dry_cbnet ro)"
out=$(CB_HOME="$ROOT/h" CB_SPAWN_DRYRUN=1 bash "$SPAWN" 5 executor /dev/null "$ROOT/w" 2>&1)
echo "$out" | grep -q "CBNET_MOUNT=-B" \
  && ok "fs_cbnet unset → default -B (back-compat)" \
  || ko "fs_cbnet unset did NOT default to -B: $out"

# 7. /cbnet flag wired into the real nsjail call; old hardcode removed
grep -qF '$CBNET_MOUNT "$CB_HOME:/cbnet"' "$SPAWN" \
  && ok "nsjail call uses \$CBNET_MOUNT for /cbnet (flag wired into real spawn)" \
  || ko "nsjail call does NOT use \$CBNET_MOUNT"
grep -qF -- '-B "$CB_HOME:/cbnet"' "$SPAWN" \
  && ko "old hardcoded '-B \$CB_HOME:/cbnet' still present (provision bypassed)" \
  || ok "old hardcoded '-B /cbnet' removed (provision is the only path)"

# 8. analyst + reviewer also locked to fs_cbnet: ro
for r in solution-analyst reviewer; do
  grep -qiE '^fs_cbnet:[[:space:]]*ro' "$HERE/../../team-example/roles/$r.md" \
    && ok "$r migrated to fs_cbnet: ro" \
    || ko "$r NOT migrated to fs_cbnet: ro"
done

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
