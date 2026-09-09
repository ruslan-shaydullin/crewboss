#!/usr/bin/env python3
"""Parse the latest explicitly structured reviewer delivery from GitHub comments."""
import json
import re
import sys


def parse(comments):
    for comment in reversed(comments):
        body = comment.get("body", "")
        match = re.search(r"^## (?:Final review|Review) \(machine\)\s*$", body, re.M | re.I)
        if not match:
            continue
        block = re.split(r"^## ", body[match.end():], maxsplit=1, flags=re.M)[0]
        fields = {}
        for line in block.splitlines():
            item = re.fullmatch(r"\s*(?:-\s*)?(verdict|target|reason)\s*:\s*(.*?)\s*", line, re.I)
            if item:
                key, value = item.groups()
                if key.lower() in fields:
                    raise ValueError("duplicate review field")
                fields[key.lower()] = value
        verdict = fields.get("verdict", "").lower()
        if verdict not in ("approve", "blocked"):
            raise ValueError("review verdict must be approve or blocked")
        target = fields.get("target", "").lstrip("#")
        if verdict == "blocked" and (not target.isdigit() or int(target) < 1):
            raise ValueError("blocked review requires target: #<leaf>")
        return {"verdict": verdict, "target": int(target) if target.isdigit() else None,
                  "reason": fields.get("reason", "")}
    return None


if __name__ == "__main__":
    try:
        payload = json.load(sys.stdin)
        comments = payload["comments"]
        if not isinstance(comments, list):
            raise ValueError("comments must be an array")
        result = parse(comments)
        if result is None:
            sys.exit(3)  # No delivery yet, distinct from malformed data/read failure.
        print(json.dumps(result))
    except (ValueError, KeyError, TypeError) as error:
        print(f"reviewer-verdict: {error}", file=sys.stderr)
        sys.exit(2)
