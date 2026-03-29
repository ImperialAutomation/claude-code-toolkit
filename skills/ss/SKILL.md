---
name: ss
description: Find Recent Screenshots
argument-hint: [number]
user-invocable: true
---

# Find Recent Screenshots

Find and display the last N screenshots from ~/Pictures/Screenshots directory.

## Input

The user provides: `$ARGUMENTS`

- If a number is provided, show that many screenshots
- If empty, default to 5 screenshots

## Usage

```bash
/ss        # Show last 5 screenshots
/ss 10     # Show last 10 screenshots
```

## Implementation

**Do NOT use Glob** — it sorts by filename, not by modification time.

Instead, use Bash to get the N most recent files:
```bash
ls -t ~/Pictures/Screenshots/*.png | head -[n]
```

Then use the Read tool to display each screenshot image.

## Output

1. Run the `ls -t` command to get the N newest file paths
2. Use the Read tool to display each screenshot image
3. Show for each file: file path and the date from the filename

**IMPORTANT:**
- Only search ~/Pictures/Screenshots - do not search other directories like Desktop, Downloads, or Pictures root
- `ls -t` sorts by actual modification time, which is the correct sort order for finding recent screenshots
