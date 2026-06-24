#!/usr/bin/env bash
#
# crewboss-gate.sh — central PreToolUse gate. Reads the PreToolUse JSON on stdin,
# branches on `agent_type` (the --agent role), enforces (A) role-scoped escalations
# and (B) the completion proof-contract. Blocks with exit code 2 (reason on stderr).
# Verified at Claude Code v2.1.161 (stdin fields tool_name/agent_type/tool_input.command;
# gh JSON fields). Spec §5.1 (close), §5.2 (green). Requires: jq, gh.
#
# Hardening (red-team): commands are whitespace-normalized before verb matching, and a
# GATED verb may only appear in a SINGLE simple command — chaining / redirect / newline
# would fool the per-command gate (e.g. `gh pr merge A && gh pr merge B`).
#
# SCOPE (honest — read before trusting this): canon() (below) folds IN-MODEL verb variants to
# the literal form before matching — quoting (`gh pr "merge"`), benign prefix (`command gh`),
# path-qualified (`/usr/bin/gh`), gh global flags (`gh -R o/r pr merge`), gh api REST for
# merge/close (`gh api …/pulls/N/merge`). Still NOT caught — adversarial EVASION, out of the
# reliability threat-model (lazy/dishonest ≠ malicious): param-expansion (`gh${IFS}pr…`),
# variable indirection (`X="gh pr merge"; $X`), `eval`, aliases, backslash line-continuation.
# push is intentionally un-gated (server-side branch protection is its anchor). This is a
# FRICTION-gate; the only bypass-proof anchors are tool-absence (`tools:`) + branch protection
# (note: `gh pr merge --admin` beats branch protection → require-admins). See spec §3 ceiling.

input="$(cat)"
jqr() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# Edit / Write / MultiEdit: deny executor from writing test files
# (independent test authorship, charter #523). All three tools expose the
# target path at .tool_input.file_path at the top level; tool_input.edits[].file_path
# is null on real MultiEdit payloads — top-level file_path is the reliable field.
_ita_tool="$(jqr '.tool_name')"
if [ "$_ita_tool" != "Bash" ]; then
  if [ "$_ita_tool" = "Edit" ] || [ "$_ita_tool" = "Write" ] || [ "$_ita_tool" = "MultiEdit" ]; then
    _ita_fp="$(jqr '.tool_input.file_path')"
    _ita_role="$(jqr '.agent_type')"; [ -n "$_ita_role" ] && [ "$_ita_role" != "null" ] || _ita_role="dev-assistant"
    if printf '%s' "$_ita_fp" | grep -Eq '(\.test\.(sh|ts|js|py)$|(^|/)tests/)'; then
      [ "$_ita_role" = "executor" ] && { printf 'crewboss BLOCK [%s]: test-file writes are test-author-only (independent test authorship, charter #523) — %s\n' "$_ita_role" "$_ita_fp" >&2; exit 2; }
    fi
  fi
  exit 0
fi

role="$(jqr '.agent_type')"
[ -n "$role" ] && [ "$role" != "null" ] || role="dev-assistant"
cmd="$(jqr '.tool_input.command')"
cmdn="$(printf '%s' "$cmd" | tr '\t\n' '  ' | tr -s ' ')"     # whitespace-normalized

# ITA Bash-path: block executor from writing test files via shell redirect/tee
if printf '%s' "$cmd" | grep -Eq '(>|>>)[[:space:]]*(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))' \
   || printf '%s' "$cmd" | grep -Eq '(^[[:space:]]*|[|;][[:space:]]*)tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(tests/|\S*(\.test\.(sh|ts|js|py)|/tests/))'; then
  [ "$role" = "executor" ] && { printf 'crewboss BLOCK [%s]: test-file writes via Bash are test-author-only (independent test authorship, charter #523)\n' "$role" >&2; exit 2; }
fi

# canon(): fold IN-MODEL verb variants to the literal form for MATCHING ONLY (never executed).
# Covers what an honest-but-over-eager agent naturally produces: quoting (gh pr "merge"),
# benign prefixes (command/builtin/exec) + path-qualified program (/usr/bin/gh), gh global
# flags (gh -R o/r pr merge), and gh api REST for merge/close. Does NOT cover adversarial
# evasion (${IFS}, $VAR, eval, alias, backslash-continuation) — out of the reliability
# threat-model by design (see header SCOPE). push is intentionally not gated (branch protection).
canon() {
  local s="$1" i out
  s="$(printf '%s' "$s" | tr -d '\042\047\134' | tr -s ' ')"                                   # 1. strip " ' \  (verb-splitting)
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(command|builtin|exec)[[:space:]]+//')"        # 2. benign prefix
  s="$(printf '%s' "$s" | sed -E 's#^[[:space:]]*/[^[:space:]]*/(gh|git)([[:space:]]|$)#\1\2#')" # 3. /path/gh -> gh
  # 4. gh api REST -> canonical proof-gated verb (write-specific paths only, no read false-deny)
  if printf '%s' "$s" | grep -Eq '(^|[[:space:]])gh[[:space:]]+api([[:space:]]|$)'; then
    if printf '%s' "$s" | grep -Eq 'pulls/[0-9]+/merge'; then
      s="gh pr merge $(printf '%s' "$s" | grep -oE 'pulls/[0-9]+/merge' | grep -oE '[0-9]+' | head -1)"
    elif printf '%s' "$s" | grep -Eq 'issues/[0-9]+' && printf '%s' "$s" | grep -Eq 'state=closed'; then
      s="gh issue close $(printf '%s' "$s" | grep -oE 'issues/[0-9]+' | grep -oE '[0-9]+' | head -1)"
    fi
  fi
  # 5. drop gh global flags so the subcommand sits next to 'gh' (gh -R o/r pr merge -> gh pr merge)
  case "$s" in
    gh\ *)
      read -ra w <<< "$s"; out="gh"; i=1
      while [ "$i" -lt "${#w[@]}" ]; do
        case "${w[i]}" in
          issue|pr|label|api|repo|release|run|auth|search|browse|status|config|gist) break ;;  # subcommand reached
          -R|--repo|-H|--hostname|-X|--method|-f|--field|-F|--raw-field|--template|-q|--jq) i=$((i+2)); continue ;;  # flag + value
          -*) i=$((i+1)); continue ;;                                                          # other flag
          *) break ;;                                                                          # bare word -> stop
        esac
      done
      out="$out ${w[*]:i}"; s="$out" ;;
  esac
  printf '%s' "$s"
}
# strip_payload(): Remove the VALUES of string-valued flags (--body/-b, --title/-t, --comment/-c)
# BEFORE canon() strips quotes. Without this, canon()'s tr-d-quote step merges body/title text
# into the canonical command string, causing GATED-verb matches on cited content (false-deny,
# P1.5 "gate false-deny quoted-payload"). Applied to cmdn (after \t/\n->space) so multiline
# bodies are already flattened to one line. Only double- and single-quoted values are stripped;
# bare single-word values are benign (they do not contain gated verb phrases).
strip_payload() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/(--body|-b|--title|-t|--comment|-c)[[:space:]]+"[^"]*"/\1/g')"
  s="$(printf '%s' "$s" | sed -E "s/(--body|-b|--title|-t|--comment|-c)[[:space:]]+'[^']*'/\\1/g")"
  printf '%s' "$s"
}
cmdc="$(canon "$(strip_payload "$cmdn")")"     # canonical form: all verb matching / number extraction runs on this

deny() { echo "crewboss BLOCK [$role]: $1" >&2; exit 2; }
has()  { printf '%s' "$cmdc" | grep -Eq "$1"; }
has_sep()     { printf '%s' "$cmd" | grep -Eq '(&&|\|\||;|\||`|\$\(|>|<)'; }   # shell metachars (ORIGINAL cmd)
has_newline() { [ "$(printf '%s' "$cmd" | wc -l | tr -d ' ')" != "0" ]; }
num_after()   { printf '%s' "$cmdc" | grep -oE "$1[[:space:]]+#?[0-9]+" | grep -oE '[0-9]+' | head -1; }

# verbs that are gated (role-escalation OR proof-gated) — must be issued singly.
GATED='gh (issue (create|delete|reopen|close)|pr (merge|ready)|label (create|delete))'

# ── boss · code-blind + exec-blind — strict allowlist, single simple command ─────────
if [ "$role" = "boss" ]; then
  { has_sep || has_newline; } && deny "boss: a single board command only (no chaining / redirect / newline)"
  printf '%s' "$cmdc" | grep -Eq '^[[:space:]]*git log' \
    && printf '%s' "$cmdc" | grep -Eq '(-p|-u|--patch|-G|-S|--format|--pretty|--stat)' \
    && deny "boss: git log content flags reveal code (code-blind)"
  printf '%s' "$cmdc" | grep -Eq '^[[:space:]]*(gh issue (create|comment|edit|list|view)|gh pr (view|list|checks)|gh label list|gh repo view|git (status|log|branch|remote)|pwd)([[:space:]]|$)' && exit 0
  deny "boss is code-blind + exec-blind — only charter-authoring (gh issue create/comment/edit) + read-only board"
fi

# ── any gated verb must be a single command (chaining/redirect defeats the per-cmd gate) ──
if has_sep || has_newline; then
  has "$GATED" && deny "a gated command (issue create/close, pr merge/ready, label) must be issued singly — no chaining / redirect / newline"
fi

# ── integrator · leaf→charter merges only (gvozd-3) ─────────────────────────────────
if [ "$role" = "integrator" ]; then
  # board-authorship and label ops: never allowed for integrator
  has 'gh (issue (create|delete|reopen)|label (create|delete))' \
    && deny "integrator: board-authorship is not permitted — only pr merge (into charter/*) and issue close"

  # gh pr merge → must target charter/<N>, all checks green; APPROVED not required (integrator
  # is the non-author verifying mechanics); charter→main is ALWAYS denied (human-only invariant)
  if has 'gh pr merge'; then
    pr="$(num_after 'gh pr merge')"
    [ -n "$pr" ] || deny "integrator merge gate: cannot parse PR number — fail closed"
    data="$(gh pr view "$pr" --json baseRefName,statusCheckRollup 2>/dev/null)"
    [ -n "$data" ] || deny "integrator merge gate: cannot read PR state — fail closed"
    base_ref="$(printf '%s' "$data" | jq -r '.baseRefName // ""')"
    printf '%s' "$base_ref" | grep -Eq '^charter/[0-9]+$' \
      || deny "integrator: merge only into charter/<N> branches — base '$base_ref' is not allowed"
    bad="$(printf '%s' "$data" | jq '[.statusCheckRollup[]? | ((.conclusion // .state) | ascii_upcase) | select(. != "SUCCESS" and . != "SKIPPED" and . != "NEUTRAL")] | length' 2>/dev/null)"
    [ "$bad" = "0" ] || deny "integrator merge gate: checks not all green on head (§5.2)"
    exit 0
  fi

  # gh issue close → leaf must have a MERGED PR into charter/* (closedByPullRequestsReferences
  # misses PRs merged into non-default branches; read head-branch PR list directly instead)
  if has 'gh issue close'; then
    n="$(num_after 'gh issue close')"
    [ -n "$n" ] || deny "integrator close gate: cannot parse issue number — fail closed"
    pr_data="$(gh pr list --head "task/$n" --state all --json number,state,baseRefName 2>/dev/null)"
    merged="$(printf '%s' "$pr_data" | jq '[.[]? | select(.state == "MERGED" and (.baseRefName | test("^charter/")))] | length' 2>/dev/null)"
    [ "$merged" != "0" ] && [ -n "$merged" ] \
      || deny "integrator close gate: no MERGED PR into charter/* for leaf #$n — fail closed"
    exit 0
  fi

  exit 0   # non-gated command for integrator — allow
fi

# ── Layer A · role-scoped escalations (gvozd-1, command level) ────────────────────────
if has 'gh (issue (create|delete|reopen|close)|pr merge|label (create|delete))'; then
  [ "$role" = "tech-lead" ] || deny "board-authorship/merge is tech-lead-only. Launch: claude --agent tech-lead"
fi

# ── Layer B · completion proof-contract (gvozd-2) ─────────────────────────────────────

# gh pr merge → non-author approval + green checks on head (§5.2)
if has 'gh pr merge'; then
  pr="$(num_after 'gh pr merge')"
  data="$(gh pr view ${pr:+"$pr"} --json reviewDecision,statusCheckRollup 2>/dev/null)"
  [ -n "$data" ] || deny "merge gate: cannot read PR state — fail closed"
  [ "$(printf '%s' "$data" | jq -r '.reviewDecision')" = "APPROVED" ] \
    || deny "merge gate: not APPROVED by a non-author (§5.2)"
  bad="$(printf '%s' "$data" | jq '[.statusCheckRollup[]? | ((.conclusion // .state) | ascii_upcase) | select(. != "SUCCESS" and . != "SKIPPED" and . != "NEUTRAL")] | length' 2>/dev/null)"
  [ "$bad" = "0" ] || deny "merge gate: checks not all green on head (§5.2)"
  exit 0
fi

# gh pr ready → green checks on head (Executor "PR ready", §5.2)
if has 'gh pr ready'; then
  pr="$(num_after 'gh pr ready')"
  data="$(gh pr view ${pr:+"$pr"} --json statusCheckRollup 2>/dev/null)"
  [ -n "$data" ] || deny "ready gate: cannot read checks — fail closed"
  bad="$(printf '%s' "$data" | jq '[.statusCheckRollup[]? | ((.conclusion // .state) | ascii_upcase) | select(. != "SUCCESS" and . != "SKIPPED" and . != "NEUTRAL")] | length' 2>/dev/null)"
  [ "$bad" = "0" ] || deny "ready gate: checks not all green on head (§5.2)"
  exit 0
fi

# gh issue close N → 5-rule (§5.1)
if has 'gh issue close'; then
  n="$(num_after 'gh issue close')"
  [ -n "$n" ] || deny "close gate: cannot parse issue number — fail closed"
  idata="$(gh issue view "$n" --json labels,body,comments,closedByPullRequestsReferences 2>/dev/null)"
  [ -n "$idata" ] || deny "close gate: cannot read issue #$n — fail closed"

  printf '%s' "$idata" | jq -e 'any(.labels[]?.name; test("^type:human-"))' >/dev/null 2>&1 \
    && deny "#$n is a human-owned task (type:human-*) — closed by a human, not the agent (§5.1)"

  has_children=0
  while read -r child; do
    [ -n "$child" ] || continue
    has_children=1
    [ "$(gh issue view "$child" --json state -q .state 2>/dev/null)" = "CLOSED" ] \
      || deny "sub-issue #$child still open — decomposition incomplete (§5.1)"
  done < <(printf '%s' "$idata" | jq -r '.body // ""' | grep -oiE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\][[:space:]]*#[0-9]+' | grep -oE '[0-9]+')

  while read -r prn; do
    [ -n "$prn" ] || continue
    [ "$(gh pr view "$prn" --json state -q .state 2>/dev/null)" = "MERGED" ] && exit 0
  done < <(printf '%s' "$idata" | jq -r '.closedByPullRequestsReferences[]?.number // empty' 2>/dev/null)

  if printf '%s' "$idata" | jq -e 'any(.labels[]?.name; test("^type:(tech-lead|analysis|research)$"))' >/dev/null 2>&1; then
    printf '%s' "$idata" | jq -e 'any(.comments[]?.body; test("crewboss-digest"; "i"))' >/dev/null 2>&1 \
      && exit 0
    deny "#$n is an analysis/tech-lead issue — post a digest comment containing 'crewboss-digest' before closing (§5.1, soft proof)"
  fi

  [ "$has_children" = "1" ] && exit 0
  deny "no gated-merged PR closes #$n and it is not a completed parent (§5.1)"
fi

exit 0   # not a gated command
