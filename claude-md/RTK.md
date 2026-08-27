# RTK - Rust Token Killer

**Usage**: Token-optimized CLI proxy (cuts up to 90% of bash output)

## What RTK Is

A CLI proxy that intercepts shell commands and compresses their output before it
reaches the model's context. Single Rust binary, 100+ supported commands, <10ms
overhead. Apache-2.0, https://github.com/rtk-ai/rtk

| Operation | What RTK does to the output |
|-----------|-----------------------------|
| `ls` / `tree` | Tree format with file counts instead of one line per entry |
| `cat` / `read` | Signatures and structure over full bodies |
| `grep` / `rg` | Truncates long lines, groups matches by file |
| `git status` | Compact stat format, grouped by state |
| `git diff` | Reduced context, headers stripped |
| `git log` | Hash, author and subject only |
| `git add/commit/push` | Confirmation line instead of full progress output |
| `pytest` / `npm test` / `cargo test` | Failures only, passing tests collapsed to a count |
| `ruff check` | Grouped by rule and file |
| `docker ps` | Essential fields only |

The "up to 90%" figure is what RTK measures on the bash output it filters — it is
not a 90% reduction of the total bill. Command output is one part of a request;
the system prompt, conversation history and file reads are unaffected.

## Meta Commands (always use rtk directly)

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
rtk discover          # Analyze Claude Code history for missed opportunities
rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
```

## Installation Verification

```bash
rtk --version         # Should show: rtk X.Y.Z
rtk gain              # Should work (not "command not found")
which rtk             # Verify correct binary
```

⚠️ **Name collision**: If `rtk gain` fails, you may have reachingforthejack/rtk (Rust Type Kit) installed instead.

## Hook-Based Usage

All other commands are automatically rewritten by the Claude Code hook.
Example: `git status` → `rtk git status` (transparent, 0 tokens overhead)

Refer to CLAUDE.md for full command reference.
