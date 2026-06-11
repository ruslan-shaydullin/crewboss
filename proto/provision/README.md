# crewboss provision + doctor — one-command bootstrap — validated (idempotent path) 2026-06-10

Turns a bare Linux box (only SSH) into a working crewboss launcher host with **one command**.
This is the consolidation of the proto rounds (3a-R6) into a shippable installer — the
release shape of `crewboss provision` / `crewboss doctor` (design §4.7).

## Cold start (the goal: fresh EC2, only SSH)
```
scp -i key.pem provision.sh ec2-user@<NEW-IP>:
ssh -i key.pem ec2-user@<NEW-IP> \
  'CREWBOSS_OAUTH_TOKEN=sk-ant-oat... GH_TOKEN=github_pat_... bash provision.sh'
```
- `CREWBOSS_OAUTH_TOKEN` — run `claude setup-token` on your laptop, paste the value.
- `GH_TOKEN` — fine-grained PAT (headless gh auth). Omit → `gh auth login` runs interactively.
- `provision.sh` is **self-contained** (the crewboss runtime is embedded as a base64 tarball),
  so it's the only file you copy.

## What provision does (idempotent — re-run is safe; each step checks-then-skips)
0. **preflight hard gates:** Linux + unprivileged user-namespaces (else exits with the exact
   `sysctl` to run, or "use a cloud VM" — userns can't be worked around, only detected).
1. base toolchain (git/jq/tar/python3/curl) via pkg-manager dispatch (dnf/apt/pacman/apk).
2. **nsjail:** prebuilt static binary from `$CREWBOSS_NSJAIL_URL` if set, else build from source.
3. gh CLI + auth (PAT or interactive).
4. claude CLI (native installer) if absent.
5. OAuth token → `~/.crewboss.env` (chmod 600); **never overwrites** an existing token.
6. deploy the embedded runtime → `$CB_HOME` (default `~/cbnet`).
7. first claude run (creates `~/.claude.json` + one-time usage approval) — skipped if present.
8. `crewboss-doctor.sh` — hard-fail health check; provision fails loudly if doctor isn't green.

## Files
- **`provision.sh`** — the built, self-contained installer (grab-and-go). 23 KB, embeds 14
  runtime files. Regenerate after any runtime change (do not hand-edit the base64 blob).
- **`provision-template.sh`** — the installer logic (source of truth).
- **`build-provision.sh`** — embeds the runtime from `$CB_SRC` (default `~/cbnet`) into the
  template → `provision.sh`. `CB_SRC=... bash build-provision.sh template out`.
- **`crewboss-doctor.sh`** — preflight + health check (also runnable standalone).

## Validation status
- **doctor: 16× green** on the live box.
- **provision idempotent path: EXIT 0, doctor green** — run on the already-set-up box into a
  scratch `CB_HOME`: every system step correctly skipped, runtime decoded, seccomp policy
  parses from the decoded location, token preserved.
- **NOT yet cold-tested:** the "do" branches (nsjail build-from-source, claude install, token
  write, gh install) need a genuinely fresh box — each is lifted from the validated
  `ec2-provision.ru.md` runbook. The cold test is the one command above on a new EC2.

## Known limits / next
- **Portability tiers:** Tier-1 = Linux x86_64 with userns (validated platform). Other arch
  (ARM64) needs the seccomp policy re-generated (`gen-policy.sh`; `SYSCALL[n]` numbers are
  arch-specific) — provision should detect arch≠x86_64 and regen instead of shipping the
  bundled `claude.kafel`. macOS/Windows-native = different sandbox backend (out of scope;
  run on a Linux box/VM).
- **Static nsjail:** ship a musl-static `nsjail` per arch as a release asset + `CREWBOSS_NSJAIL_URL`
  so step 2 downloads instead of building (kills the build-deps mine across distros). Pin
  version + checksum (kafel syscall-table quirks make version drift behavior-changing).
- Only the dnf path of gh/nsjail-deps is live-tested; apt/pacman/apk dispatch is written but
  unverified.
