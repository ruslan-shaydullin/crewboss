#!/usr/bin/env bash
# Test-host prerequisite. Run only on a disposable Ubuntu 24.04 VM/CI runner.
set -euo pipefail
if [ "$(uname -s)" != Linux ]; then echo 'nsjail requires Linux' >&2; exit 2; fi
NSJAIL_COMMIT=f78475530b46d0186111a9096b30725f816b55fe # upstream 3.6
sudo apt-get update -qq
sudo apt-get install -y autoconf bison flex gcc g++ git libprotobuf-dev libnl-route-3-dev libtool make pkg-config protobuf-compiler jq python3 perl
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
git -C "$build_dir" init -q
git -C "$build_dir" remote add origin https://github.com/google/nsjail.git
git -C "$build_dir" fetch --depth=1 origin "$NSJAIL_COMMIT"
git -C "$build_dir" checkout --detach FETCH_HEAD
test "$(git -C "$build_dir" rev-parse HEAD)" = "$NSJAIL_COMMIT"
git -C "$build_dir" submodule update --init --depth=1
make -C "$build_dir" -j2
sudo install -m 0755 "$build_dir/nsjail" /usr/local/bin/nsjail
# Ubuntu restricts unprivileged user namespaces through AppArmor. Permit only
# this explicitly installed jail executable; retain the host-wide restriction.
if command -v apparmor_parser >/dev/null 2>&1; then
  sudo tee /etc/apparmor.d/crewboss-nsjail >/dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>
/usr/local/bin/nsjail flags=(unconfined) {
  userns,
}
PROFILE
  sudo apparmor_parser -r /etc/apparmor.d/crewboss-nsjail
fi
/usr/local/bin/nsjail --help >/dev/null
