# Round 4 — full edit→PR slice in a jail hardened by all THREE layers — validated 2026-06-10

## 4b — the AGENT pushes its own PR from inside the jail (full executor motion)
- **Succeeded first try** under the existing hardened policy: issue #5 → floor preps
  branch → **claude itself** does edit + commit + push + `gh pr create` **inside the
  FS+net+seccomp(KILL) jail**, 12 turns, $0.158, is_error=false → agent opens **real
  [PR #6](https://github.com/stratch1989/crewboss-proto/pull/6)** (commit `ad0be7d`).
- **All git+gh egress went through the proxy** (egress log: api.anthropic.com inference +
  github.com push + api.github.com `gh pr create`) — no bypass. seccomp covered claude
  spawning git/gh as subprocesses with no policy change needed (3c surface already had them).
- The agent self-resolved git identity (no `.gitconfig` mounted; it ran `git config` and
  retried — that's part of the 12 turns). To skip the wasted turns in prod, pass
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env or mount a bot `.gitconfig`.
- `gh` repo detection: fetch-url is the local mirror, so `gh` needs **`GH_REPO=OWNER/REPO`**
  (design §4.4 grable) — passed as env; with it `gh pr create` works.
- **4b vs 4a:** 4a the floor pushes (agent edits only); 4b the agent does the whole git+gh
  motion itself with `GH_TOKEN` in-jail. 4b is the real executor; 4a is the safer split.

---

## 4a — full edit→PR slice in a jail hardened by all THREE layers — validated 2026-06-10

Rounds 3a/3b/3c proved each isolation layer **separately**. Round 4a runs them
**together in one nsjail profile** through the real executor motion: claude edits a
file inside the tight jail, the host-side floor opens a real PR.

## Result
- **Slice succeeded:** issue #3 → claude appends a line to `README.md` **inside the jail
  hardened with FS (3a) + net (3b) + seccomp KILL_PROCESS (3c) at once** (rc=0,
  is_error=false, $0.044) → floor (host, trusted) commits + pushes + opens **real
  [PR #4](https://github.com/stratch1989/crewboss-proto/pull/4)**.
- **Three layers simultaneously active** (`run-r4-sanity.sh`, one jail):
  - NET: api.github.com → 200; example.com → CONNECT 403.
  - SECCOMP: mount(165) and ptrace(101) → SIGSYS kill (rc 159).
  - FS: host secret `~/.crewboss.env` absent; only curated mounts visible under HOME.

## Edit surface
`run-r4-discover.sh` traced claude EDITING a file (vs the 3c smoke "reply OK"). Delta
over the 3c union: a single new syscall — **`fchmod`** (already in the essentials
buffer). r4 union = 112. So editing barely widens the surface; the 3c policy already
covered it.

## Division of labour (design §4.4/§4.5)
- **Agent (in tight jail):** edits code only. Needs net to anthropic for inference;
  does NOT need github or a token for a local edit. No git.
- **Floor (host, outside jail, trusted deterministic code):** mirror → local clone →
  push-url fix → branch → [agent edits] → commit → push → `gh pr create`. Uses the host
  network directly (no proxy — floor is trusted).

## Policy generation is now automatic
`gen-policy.sh <union-list>` builds `claude.kafel`: names kafel's amd64 table knows go in
by name, names it doesn't (stat/fstat/lstat/sendfile/uname) are auto-mapped to
`SYSCALL[nr]` via `ausyscall --exact`, dangerous syscalls are stripped even if discovered,
and the whole policy is parse-checked. Re-run it whenever the workload surface changes.

## Still open (rest of Round 4)
- **4b — executor role pushes its own PR from inside the jail** (`claude --agent executor`,
  agent itself runs git+gh through the proxy). Needs the agent+git-from-claude surface
  re-captured and GH_TOKEN in-jail. Today the floor pushes.
- merge-gate on a live PR; charter branches; node→20 + Expo gate; fine-grained PAT;
  the real Quarter repo.
