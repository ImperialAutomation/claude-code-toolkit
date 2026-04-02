#!/usr/bin/env bash
# json-find-key.sh — Find where a key exists in a nested JSON file
#
# Usage: json-find-key.sh <key> <file> [--values]
#   <key>      The key name to search for (e.g. "deletion", "subscription")
#   <file>     Path to the JSON file
#   --values   Also show the immediate child keys of each match
#
# Examples:
#   json-find-key.sh deletion frontend/src/i18n/locales/nl.json
#   # Output: billing.deletion
#
#   json-find-key.sh deletion frontend/src/i18n/locales/nl.json --values
#   # Output: billing.deletion (keys: dangerZone, dangerZoneDescription, deleteAccount, ...)

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: json-find-key.sh <key> <file> [--values]" >&2
    exit 1
fi

KEY="$1"
FILE="$2"
SHOW_VALUES="${3:-}"

if [[ ! -f "$FILE" ]]; then
    echo "Error: file not found: $FILE" >&2
    exit 1
fi

python3 -c "
import json, sys

key = sys.argv[1]
show_values = '--values' in sys.argv[3:]

with open(sys.argv[2]) as f:
    data = json.load(f)

found = False

def search(d, path=''):
    global found
    for k, v in d.items():
        current = f'{path}.{k}' if path else k
        if k == key:
            found = True
            if show_values and isinstance(v, dict):
                child_keys = ', '.join(list(v.keys())[:8])
                if len(v) > 8:
                    child_keys += ', ...'
                print(f'{current} (keys: {child_keys})')
            elif show_values and not isinstance(v, dict):
                val = str(v)[:60]
                print(f'{current} = {val}')
            else:
                print(current)
        if isinstance(v, dict):
            search(v, current)

search(data)
if not found:
    print(f'Key \"{key}\" not found in {sys.argv[2]}', file=sys.stderr)
    sys.exit(1)
" "$KEY" "$FILE" "$SHOW_VALUES"
