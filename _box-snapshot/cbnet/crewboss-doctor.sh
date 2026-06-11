#!/usr/bin/env bash
# crewboss doctor — preflight + health check. Hard-fails on blockers with a remediation
# hint (never warn-and-continue on a security/correctness invariant). Also the installer's
# first and last step. Exit 0 = healthy, 1 = at least one FAIL.
# Env: CB_HOME (default ~/cbnet), CB_REPO (owner/repo for push-URL check; optional).
set -uo pipefail
CB_HOME="${CB_HOME:-$HOME/cbnet}"
ENVFILE="${CREWBOSS_ENV:-$HOME/.crewboss.env}"
fails=0; warns=0
FAIL(){ printf '  \033[31mFAIL\033[0m %s\n        ↳ %s\n' "$1" "$2"; fails=$((fails+1)); }
WARN(){ printf '  \033[33mWARN\033[0m %s\n        ↳ %s\n' "$1" "$2"; warns=$((warns+1)); }
OK(){   printf '  \033[32mok\033[0m   %s\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

echo "crewboss doctor — $(uname -s) $(uname -m), kernel $(uname -r)"

# --- platform (hard) ---
[ "$(uname -s)" = "Linux" ] || FAIL "Linux required" "nsjail uses Linux namespaces; on macOS/Windows run on a Linux box/VM"
maxuserns=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)
if [ "${maxuserns:-0}" -gt 0 ] && unshare -Ur true 2>/dev/null; then
  OK "unprivileged user namespaces enabled (max=$maxuserns)"
else
  FAIL "unprivileged user namespaces disabled" "enable: sudo sysctl -w kernel.unprivileged_userns_clone=1 (Debian/Ubuntu) / user.max_user_namespaces>0; or use a cloud VM. Without this, mapped-root = real host root."
fi

# --- toolchain (hard) ---
for t in git jq python3 curl; do have "$t" && OK "$t present" || FAIL "$t missing" "install via your package manager"; done
have gh && OK "gh present ($(gh --version | head -1))" || FAIL "gh missing" "install GitHub CLI (cli.github.com)"
if [ -x "$HOME/.local/bin/claude" ] || have claude; then OK "claude present"; else FAIL "claude CLI missing" "curl -fsSL https://claude.ai/install.sh | bash"; fi

# --- nsjail + seccomp (hard) ---
NSJAIL="$(command -v nsjail || echo /usr/local/bin/nsjail)"
if [ -x "$NSJAIL" ] && "$NSJAIL" -Mo --disable_clone_newnet --really_quiet -R /usr -R /bin -R /lib -R /lib64 -- /bin/true >/dev/null 2>&1; then
  OK "nsjail runs ($NSJAIL)"
else
  FAIL "nsjail missing or non-functional" "provision builds/install it to /usr/local/bin/nsjail"
fi
POL="$CB_HOME/claude.kafel"
if [ -f "$POL" ]; then
  if "$NSJAIL" -Mo --disable_clone_newnet --really_quiet -R /usr -R /bin -R /lib -R /lib64 -R /sbin -R /etc --seccomp_policy "$POL" -- /bin/true 2>&1 | grep -q "Couldn't prepare"; then
    FAIL "seccomp policy does not parse" "regenerate with gen-policy.sh (arch-specific SYSCALL[n] may have drifted)"
  else OK "seccomp policy parses ($POL)"; fi
else
  FAIL "seccomp policy absent ($POL)" "provision ships/generates claude.kafel — no third nail without it"
fi

# --- auth invariants (hard) ---
# shellcheck disable=SC1090
[ -f "$ENVFILE" ] && . "$ENVFILE" 2>/dev/null
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then OK "CLAUDE_CODE_OAUTH_TOKEN set"; else FAIL "CLAUDE_CODE_OAUTH_TOKEN unset" "claude setup-token on your laptop -> put in $ENVFILE (chmod 600)"; fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then FAIL "ANTHROPIC_API_KEY is set" "must be EMPTY — it outranks OAuth and would bill the paid API. unset it."; else OK "ANTHROPIC_API_KEY empty (OAuth wins)"; fi
if [ -f "$ENVFILE" ]; then
  m=$(stat -c '%a' "$ENVFILE" 2>/dev/null || stat -f '%Lp' "$ENVFILE" 2>/dev/null)
  [ "$m" = "600" ] && OK "$ENVFILE mode 600" || FAIL "$ENVFILE mode $m" "chmod 600 $ENVFILE — it holds the OAuth token"
fi
[ -d "$HOME/.claude" ] && OK "~/.claude (dir) present" || WARN "~/.claude dir absent" "created on first claude run"
[ -f "$HOME/.claude.json" ] && OK "~/.claude.json (file) present" || WARN "~/.claude.json absent" "created on first claude run (separate from the dir; jail needs both)"
if have gh && gh auth status >/dev/null 2>&1; then OK "gh authenticated"; else WARN "gh not authenticated" "gh auth login, or set a fine-grained GH_TOKEN (PAT)"; fi

# --- runtime files (hard-ish) ---
for f in proxy.py bridge.py redact.pl crewboss-spawn.sh crewboss-launcher-gh.sh board-gh.sh launchable.sh; do
  [ -f "$CB_HOME/$f" ] && OK "runtime: $f" || FAIL "runtime missing: $CB_HOME/$f" "provision deploys the crewboss runtime to $CB_HOME"; done

# --- push-URL resolves to github (optional) ---
if [ -n "${CB_REPO:-}" ]; then
  if gh repo view "$CB_REPO" >/dev/null 2>&1; then OK "push target $CB_REPO reachable"; else WARN "push target $CB_REPO not reachable" "check GH_TOKEN scope / repo name"; fi
fi

echo
if [ "$fails" -gt 0 ]; then echo "doctor: $fails FAIL, $warns warn — NOT healthy"; exit 1
else echo "doctor: healthy ($warns warn)"; fi
