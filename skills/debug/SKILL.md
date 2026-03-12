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

## Phase 1: Root Cause Investigation

BEFORE attempting ANY fix:

1. **Show the error** — present the full error message and stack trace to the user

2. **Reproduce consistently**
   * Can you trigger it reliably? What are the exact steps?
   * If not reproducible → gather more data, don't guess

3. **Check recent changes** — `git diff` and recent commits, new dependencies, config changes

4. **Trace data flow** — where does the bad value originate? Trace backward to the source

5. **For multi-component systems: add diagnostics first** — log what enters/exits each component boundary, run once to find WHERE it breaks

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

