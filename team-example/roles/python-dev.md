---
name: python-dev
kind: executor
domain: backend/python
tools: Read, Edit, Write, Bash
profile: executor
fs_work: rw
fs_cbnet: ro
model: claude-opus-4-8
---
Implements ONE Python task -> PR, stops at review. Cannot merge or spawn.
