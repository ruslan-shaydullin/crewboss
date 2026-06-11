#!/usr/bin/env bash
# crewboss provision — self-contained one-command bootstrap for a fresh Linux box.
# Turns a bare box (only SSH) into a working crewboss launcher host. IDEMPOTENT.
#
#   CREWBOSS_OAUTH_TOKEN=sk-ant-oat... [GH_TOKEN=github_pat_...] bash provision.sh
#
# OAuth token: run `claude setup-token` on your laptop, paste the value here.
# GH_TOKEN (fine-grained PAT) = headless gh auth; omit to run `gh auth login` interactively.
# Env: CB_HOME (default ~/cbnet), CREWBOSS_NSJAIL_URL (prebuilt static nsjail; else build).
set -euo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"
ENVF="$HOME/.crewboss.env"
step(){ printf '\n\033[36m=== %s ===\033[0m\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

step "0. preflight (hard gates)"
[ "$(uname -s)" = "Linux" ] || { echo "Linux only — on macOS/Windows run on a Linux box/VM"; exit 1; }
if ! { [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null||echo 0)" -gt 0 ] && unshare -Ur true 2>/dev/null; }; then
  echo "unprivileged user namespaces are DISABLED."
  echo "  enable: sudo sysctl -w kernel.unprivileged_userns_clone=1   (Debian/Ubuntu)"
  echo "      or: sudo sysctl -w user.max_user_namespaces=10000"
  echo "  or use a cloud VM. Without userns, the jail's mapped-root would be real host root."
  exit 1
fi
echo "Linux $(uname -m), userns ok"

# package-manager dispatch (portability seam)
if   have dnf;     then PKG(){ sudo dnf -y install "$@"; };  NSDEPS="gcc gcc-c++ make autoconf bison flex libtool pkgconf-pkg-config protobuf-devel protobuf-compiler libnl3-devel"
elif have apt-get; then PKG(){ sudo apt-get -y install "$@"; }; sudo apt-get update -y || true; NSDEPS="build-essential autoconf bison flex libtool libprotobuf-dev protobuf-compiler libnl-route-3-dev pkg-config"
elif have pacman;  then PKG(){ sudo pacman -S --noconfirm "$@"; }; NSDEPS="base-devel autoconf bison flex libtool protobuf libnl pkgconf"
elif have apk;     then PKG(){ sudo apk add "$@"; }; NSDEPS="build-base autoconf bison flex libtool protobuf-dev libnl3-dev pkgconf linux-headers"
else echo "no supported package manager (dnf/apt/pacman/apk)"; exit 1; fi

step "1. base toolchain"
for t in git jq tar python3 curl; do have "$t" || PKG "$t"; done
echo "toolchain ok"

step "2. nsjail (static prebuilt -> else build from source)"
if [ -x /usr/local/bin/nsjail ]; then echo "nsjail present, skip"
elif [ -n "${CREWBOSS_NSJAIL_URL:-}" ] && curl -fsSL "$CREWBOSS_NSJAIL_URL" -o /tmp/nsjail.bin && file /tmp/nsjail.bin | grep -q ELF; then
  sudo install -m 755 /tmp/nsjail.bin /usr/local/bin/nsjail; echo "nsjail installed (prebuilt)"
else
  echo "building nsjail from source..."; PKG $NSDEPS
  rm -rf /tmp/nsjail-src; git clone --depth 1 https://github.com/google/nsjail /tmp/nsjail-src
  make -C /tmp/nsjail-src -j"$(nproc)"; sudo install -m 755 /tmp/nsjail-src/nsjail /usr/local/bin/nsjail; rm -rf /tmp/nsjail-src
fi
/usr/local/bin/nsjail --help >/dev/null 2>&1 && echo "nsjail ok"

step "3. gh CLI + auth"
if ! have gh; then
  if have dnf; then sudo dnf -y install dnf-plugins-core && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo && sudo dnf -y install gh
  elif have apt-get; then (type -p wget >/dev/null||sudo apt-get install -y wget); sudo mkdir -p -m 755 /etc/apt/keyrings; wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null; echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null; sudo apt-get update -y && sudo apt-get install -y gh
  else PKG github-cli || PKG gh; fi
fi
if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN" | gh auth login --with-token && echo "gh: PAT auth ok"
elif gh auth status >/dev/null 2>&1; then echo "gh already authenticated"
else echo "no GH_TOKEN -> interactive login:"; gh auth login; fi

step "4. claude CLI"
if [ -x "$HOME/.local/bin/claude" ] || have claude; then echo "claude present, skip"
else curl -fsSL https://claude.ai/install.sh | bash; fi
export PATH="$HOME/.local/bin:$PATH"

step "5. OAuth token + env (never overwrite; ANTHROPIC_API_KEY must stay empty)"
if [ -f "$ENVF" ] && grep -q CLAUDE_CODE_OAUTH_TOKEN "$ENVF"; then echo "token present in $ENVF, keep"
elif [ -n "${CREWBOSS_OAUTH_TOKEN:-}" ]; then printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CREWBOSS_OAUTH_TOKEN" > "$ENVF"; chmod 600 "$ENVF"; echo "wrote $ENVF (600)"
else echo "MISSING token: re-run with CREWBOSS_OAUTH_TOKEN=... (from 'claude setup-token')"; exit 1; fi

step "6. deploy crewboss runtime -> $CB_HOME"
mkdir -p "$CB_HOME"
base64 -d <<'__RUNTIME_B64__' | tar -xzC "$CB_HOME"
__RUNTIME_PLACEHOLDER__
__RUNTIME_B64__
chmod +x "$CB_HOME"/*.sh "$CB_HOME"/*.pl 2>/dev/null || true
echo "runtime: $(ls "$CB_HOME" | wc -l) files"

step "7. first claude run (creates ~/.claude.json + usage approval)"
# shellcheck disable=SC1090
. "$ENVF"; export CLAUDE_CODE_OAUTH_TOKEN; unset ANTHROPIC_API_KEY 2>/dev/null || true
if [ -f "$HOME/.claude.json" ]; then echo "~/.claude.json present, skip first-run"
else echo "running smoke (also triggers one-time usage approval)..."; "$HOME/.local/bin/claude" -p "Reply with exactly: OK" --output-format json >/dev/null 2>&1 || echo "(smoke non-fatal; re-check with doctor)"; fi

step "8. doctor"
CB_HOME="$CB_HOME" bash "$CB_HOME/crewboss-doctor.sh" || { echo; echo "provision finished with doctor FAILs — see above"; exit 1; }
echo; echo "crewboss provisioned. runtime in $CB_HOME ; token in $ENVF"
