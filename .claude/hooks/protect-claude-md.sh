#!/usr/bin/env bash
# PreToolUse hook: block direct Edit/Write/MultiEdit calls against CLAUDE.md.
# CLAUDE.md changes must be proposed as a diff in chat for human review
# (see CLAUDE.md's own "edits require approval" rule).

input="$(cat)"
file_path="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tool_input",{}).get("file_path",""))' 2>/dev/null)"

if [ -z "$file_path" ]; then
    # Fall back to a plain grep-based extraction if python3 isn't available.
    file_path="$(printf '%s' "$input" | grep -o '"file_path" *: *"[^"]*"' | head -n1 | sed -E 's/.*: *"(.*)"/\1/')"
fi

base="$(basename -- "$file_path" 2>/dev/null)"

if [ "$base" = "CLAUDE.md" ]; then
    echo "CLAUDE.md edits require human review. Propose a diff in chat instead of editing this file directly — do not retry this write." >&2
    exit 2
fi

exit 0
