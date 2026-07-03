#!/usr/bin/env bash
# manifest-doctor — validate a crewboss team manifest (org.json + roles/*.md + rubric.json)
# against the hard invariants of org-model.ru.md. Exit 0 = valid. Run from the manifest dir.
set -u
DIR="${1:-.}"; ORG="$DIR/org.json"; ROLES="$DIR/roles"
fail=0; FAIL(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }; OK(){ printf '  \033[32mok\033[0m   %s\n' "$1"; }
[ -f "$ORG" ] || { echo "no org.json at $ORG"; exit 2; }
jq -e . "$ORG" >/dev/null 2>&1 || { echo "org.json does not parse"; exit 2; }

field(){ sed -n '/^---$/,/^---$/p' "$ROLES/$1.md" 2>/dev/null | grep -iE "^$2:" | head -1 | sed -E "s/^[^:]*:[[:space:]]*//"; }
has(){ printf '%s' "$2" | grep -qiw "$1"; }
roles_in_org(){ jq -r '.nodes[].role' "$ORG"; }
span_max=$(jq -r '.policy.span_max // 5' "$ORG")

echo "== structure =="
roots=$(jq '[.nodes[]|select(.reports_to==null)]|length' "$ORG")
[ "$roots" = 1 ] && OK "exactly one root" || FAIL "roots=$roots (want 1)"
# every role file exists; every reports_to resolves
for r in $(roles_in_org); do [ -f "$ROLES/$r.md" ] || FAIL "node role '$r' has no roles/$r.md"; done
while read -r p; do [ "$p" = null ] && continue
  jq -e --arg p "$p" 'any(.nodes[]; .role==$p)' "$ORG" >/dev/null || FAIL "reports_to '$p' is not a node"
done < <(jq -r '.nodes[].reports_to' "$ORG")
# span <= max
while read -r r; do
  c=$(jq --arg r "$r" '[.nodes[]|select(.reports_to==$r)]|length' "$ORG")
  [ "$c" -le "$span_max" ] && OK "span(#$r)=$c <= $span_max" || FAIL "span(#$r)=$c > $span_max"
done < <(roles_in_org | sort -u)

echo "== role invariants =="
top=$(jq -r '.policy.approval_role' "$ORG")
for r in $(roles_in_org | sort -u); do
  [ -f "$ROLES/$r.md" ] || continue
  k=$(field "$r" kind); t=$(field "$r" tools); cb=$(field "$r" code_blind)
  case "$k" in
    manager)
      { has Edit "$t" || has Write "$t" || has Agent "$t"; } && FAIL "manager '$r' must NOT have Edit/Write/Agent (has: $t)" || OK "manager '$r' has no code/spawn tools"
      # code_blind is a no-write capability (fs_work: ro) and is compatible with Read: dept
      # managers/leads stay code_blind yet still Read to review PRs. Only the org top
      # (approval_role) is *fully* code-blind — it must carry no Read at all.
      if [ "$cb" = "true" ] && [ "$r" = "$top" ]; then
        has Read "$t" && FAIL "code-blind top '$r' must NOT have Read" || OK "top '$r' code-blind (no Read)"
      fi ;;
    analyst)
      { has Edit "$t" || has Write "$t" || has Agent "$t"; } && FAIL "analyst '$r' must be read-only (has: $t)" || OK "analyst '$r' read-only" ;;
    executor)
      { has Edit "$t" || has Write "$t"; } && OK "executor '$r' can write code" || FAIL "executor '$r' has no Edit/Write" ;;
    *) FAIL "role '$r' has unknown kind '$k' (executor|analyst|manager)" ;;
  esac
done

echo "== policy =="
ap=$(jq -r '.policy.approval_role' "$ORG"); [ -f "$ROLES/$ap.md" ] && OK "approval_role '$ap' exists" || FAIL "approval_role '$ap' missing"
[ "$(field "$ap" kind)" = manager ] && OK "approval_role is a manager" || FAIL "approval_role '$ap' must be a manager"
for a in $(jq -r '.policy.analysis_roles[]' "$ORG"); do
  [ -f "$ROLES/$a.md" ] || { FAIL "analysis_role '$a' missing"; continue; }
  [ "$(field "$a" kind)" = analyst ] && OK "analysis_role '$a' is an analyst" || FAIL "analysis_role '$a' must be an analyst" ; done
for h in $(jq -r '.departments[].head' "$ORG"); do
  [ "$(field "$h" kind)" = manager ] && OK "dept head '$h' is a manager" || FAIL "dept head '$h' must be a manager" ; done

echo; [ "$fail" = 0 ] && echo "manifest-doctor: VALID" || { echo "manifest-doctor: $fail problem(s)"; exit 1; }
