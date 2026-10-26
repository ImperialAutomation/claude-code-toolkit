#!/bin/bash
# Add hooks from claude-md/settings-global.jsonc that are missing in
# ~/.claude/settings.json. Thin exec wrapper; the implementation and the rules
# for what counts as missing are in lib/settings_sync_hooks.py.
#
# Usage: settings-sync-hooks.sh [--dry-run] [--settings PATH] [--template PATH]
exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/settings_sync_hooks.py" "$@"
