#!/usr/bin/env bash
# ops-roles.test.sh — unit tests for ops-role agent manifests (issue #273)
#
# Asserts that each of the 4 ops-role manifests exists, has valid frontmatter
# (name matches filename, tools subset of {Read,Edit,Write,Bash}, non-empty
# description and persona body), and enforces least-privilege:
#   observer / test-planner  → no Write, no Edit
#   git-resolver             → no Write (Edit only)
#   role-builder             → no Edit  (Write only)
#
# Class: unit, pure (grep/parse files, no processes spawned)
# Self-classification: ALLOW
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$HERE/../.claude/agents"

pass=0; fail=0
ok(){ printf "  ok   %s\n" "$1"; pass=$((pass+1)); }
no(){ printf "  FAIL %s\n" "$1"; fail=$((fail+1)); }

# ── helpers ───────────────────────────────────────────────────────────────────

# get_frontmatter_field FILE FIELD
# Prints the value of FIELD from the first --- block, or empty string.
get_frontmatter_field(){
    local file="$1" field="$2"
    awk -v f="$field" '
        BEGIN{in_fm=0}
        /^---$/{in_fm=!in_fm; next}
        in_fm && $0 ~ ("^" f ":") {
            sub("^" f ": *", "")
            print
            exit
        }
    ' "$file" 2>/dev/null
}

# has_persona FILE — true if there is any non-empty line after the closing ---
has_persona(){
    local file="$1"
    awk '
        BEGIN{fm=0;cnt=0}
        /^---$/{fm++; next}
        fm>=2 && NF>0{cnt++; exit}
        END{exit (cnt==0)}
    ' "$file" 2>/dev/null
}

# tools_csv_to_list CSV — echo one token per line
tools_csv_to_list(){
    echo "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$'
}

# has_tool CSV TOKEN — true if TOKEN is in the CSV list
has_tool(){
    tools_csv_to_list "$1" | grep -qxF "$2"
}

# validate_tools CSV — true if all tokens are in {Read,Edit,Write,Bash}
validate_tools(){
    local bad=0
    while IFS= read -r tok; do
        case "$tok" in
            Read|Edit|Write|Bash) ;;
            *) bad=1 ;;
        esac
    done < <(tools_csv_to_list "$1")
    return $bad
}

# ── per-file checks ───────────────────────────────────────────────────────────
check_manifest(){
    local slug="$1"
    local file="$AGENTS_DIR/${slug}.md"

    # T1: file exists
    if [ ! -f "$file" ]; then
        no "[$slug] file exists: $file"
        no "[$slug] name field matches filename"
        no "[$slug] tools field present"
        no "[$slug] tools are valid subset"
        no "[$slug] description non-empty"
        no "[$slug] persona body non-empty"
        return
    fi
    ok "[$slug] file exists"

    # T2: name == slug
    local name
    name="$(get_frontmatter_field "$file" "name")"
    [ "$name" = "$slug" ] \
        && ok "[$slug] name='$slug' matches filename" \
        || no "[$slug] name field: expected '$slug', got '$name'"

    # T3: tools field present and non-empty
    local tools
    tools="$(get_frontmatter_field "$file" "tools")"
    [ -n "$tools" ] \
        && ok "[$slug] tools field present" \
        || no "[$slug] tools field missing or empty"

    # T4: all tools are valid
    if [ -n "$tools" ]; then
        if validate_tools "$tools"; then
            ok "[$slug] tools are valid subset of {Read,Edit,Write,Bash}"
        else
            no "[$slug] tools contain invalid token(s): '$tools'"
        fi
    fi

    # T5: description non-empty
    local desc
    desc="$(get_frontmatter_field "$file" "description")"
    [ -n "$desc" ] \
        && ok "[$slug] description non-empty" \
        || no "[$slug] description is empty"

    # T6: persona body non-empty (lines after closing ---)
    if has_persona "$file"; then
        ok "[$slug] persona body non-empty"
    else
        no "[$slug] persona body is empty"
    fi
}

# ── least-privilege checks ────────────────────────────────────────────────────
check_no_tool(){
    local slug="$1" banned="$2"
    local file="$AGENTS_DIR/${slug}.md"
    [ ! -f "$file" ] && { no "[$slug] least-priv $banned: file missing (skip)"; return; }
    local tools
    tools="$(get_frontmatter_field "$file" "tools")"
    if has_tool "$tools" "$banned"; then
        no "[$slug] least-privilege: MUST NOT have '$banned' (tools='$tools')"
    else
        ok "[$slug] least-privilege: no '$banned' tool (correct)"
    fi
}

check_has_tool(){
    local slug="$1" required="$2"
    local file="$AGENTS_DIR/${slug}.md"
    [ ! -f "$file" ] && { no "[$slug] required tool $required: file missing (skip)"; return; }
    local tools
    tools="$(get_frontmatter_field "$file" "tools")"
    if has_tool "$tools" "$required"; then
        ok "[$slug] has required tool '$required'"
    else
        no "[$slug] MISSING required tool '$required' (tools='$tools')"
    fi
}

# =============================================================================
echo "=== T1-T6: manifest structure checks ==="
check_manifest "git-resolver"
check_manifest "observer"
check_manifest "role-builder"
check_manifest "test-planner"

echo
echo "=== T7: least-privilege — observer (Read, Bash only) ==="
check_no_tool  "observer" "Write"
check_no_tool  "observer" "Edit"
check_has_tool "observer" "Read"
check_has_tool "observer" "Bash"

echo
echo "=== T8: least-privilege — test-planner (Read, Bash only) ==="
check_no_tool  "test-planner" "Write"
check_no_tool  "test-planner" "Edit"
check_has_tool "test-planner" "Read"
check_has_tool "test-planner" "Bash"

echo
echo "=== T9: least-privilege — git-resolver (Read, Edit, Bash; no Write) ==="
check_no_tool  "git-resolver" "Write"
check_has_tool "git-resolver" "Edit"
check_has_tool "git-resolver" "Read"
check_has_tool "git-resolver" "Bash"

echo
echo "=== T10: least-privilege — role-builder (Read, Write, Bash; no Edit) ==="
check_no_tool  "role-builder" "Edit"
check_has_tool "role-builder" "Write"
check_has_tool "role-builder" "Read"
check_has_tool "role-builder" "Bash"

echo
printf "=== SUMMARY: %d passed, %d failed ===\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
