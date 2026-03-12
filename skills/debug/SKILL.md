---
name: debug
description: Systematic debugging - find root cause before attempting fixes
argument-hint: "<description of the bug or error>"
user-invocable: true
---

# Systematic Debugging

Find the root cause before attempting any fix. Random fixes waste time and create new bugs.

## Input

The user describes a bug, error, or unexpected behavior: `$ARGUMENTS`

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you haven't completed Phase 1, you CANNOT propose fixes.

## Tool Rules

- Use Glob to find files — NEVER use `find` or `ls` via Bash
- Use Grep to search file contents — NEVER use `grep` or `rg` via Bash
- Use Read to read files — NEVER use `cat`, `head`, or `tail` via Bash
- Bash is for `gh` commands, `git` commands, running tests, and `~/.claude/bin/` scripts only
- NEVER write files via Bash (no `echo >`, `cat <<`, `tee`, heredoc) — use the Write tool to write to `/tmp/`, then reference the file
- NEVER use `python3 -c`, `sed`, or `awk` for file modifications — use Grep to find occurrences, then Edit to replace them
- For batch operations on multiple issues, ALWAYS use `~/.claude/bin/` scripts

## Phase 1: Root Cause Investigation

BEFORE attempting ANY fix:

1. **Read error messages carefully**
   * Don't skip past errors or warnings — they often contain the answer
   * Read stack traces completely, note line numbers and file paths
   * Show the error to the user

2. **Reproduce consistently**
   * Can you trigger it reliably? What are the exact steps?
   * If not reproducible → gather more data, don't guess

3. **Check recent changes**
   * `git diff` and recent commits — what changed?
   * New dependencies, config changes, environmental differences?

4. **Trace data flow**
   * Where does the bad value originate?
   * Trace backward through the call stack until you find the source
   * Fix at source, not at symptom

5. **For multi-component systems: add diagnostics first**
   * Log what enters and exits each component boundary
   * Run once to gather evidence showing WHERE it breaks
   * Then investigate that specific component

## Phase 2: Pattern Analysis

1. **Find working examples** — locate similar working code in the same codebase
2. **Compare** — what's different between working and broken? List every difference
3. **Understand dependencies** — what settings, config, environment does this need?

## Phase 3: Hypothesis & Test

1. **Form a single hypothesis** — "I think X is the root cause because Y"
2. **Test minimally** — smallest possible change, one variable at a time
3. **Verify** — did it work? If not, form a NEW hypothesis. Don't stack fixes

## Phase 4: Fix with TDD

1. **Write a failing test** that reproduces the bug
2. **Implement the fix** — address root cause, ONE change only, no "while I'm here" improvements
3. **Verify** — test passes, no other tests broken, issue actually resolved
4. **Commit** with message explaining what caused the bug and how it was fixed

## The 3-Fix Rule

If you've tried 3 fixes and none worked:

**STOP. Do not attempt fix #4.**

This pattern indicates an architectural problem, not a bug:
- Each fix reveals new shared state or coupling
- Fixes require "massive refactoring"
- Each fix creates new symptoms elsewhere

Discuss with the user before continuing. This is not a failed hypothesis — this is a wrong architecture.

## Red Flags — STOP and Return to Phase 1

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- "Add multiple changes, run tests"

ALL of these mean: STOP. You're guessing. Return to Phase 1.

## Quick Reference

| Phase | Key Activity | Done when |
|-------|-------------|-----------|
| 1. Root Cause | Read errors, reproduce, trace data flow | You understand WHAT and WHY |
| 2. Pattern | Find working examples, compare differences | You identified the discrepancy |
| 3. Hypothesis | Form theory, test one variable | Confirmed or new hypothesis |
| 4. Fix | Failing test → fix → green → commit | Bug resolved, tests pass |
