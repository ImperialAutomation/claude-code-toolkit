#!/usr/bin/env python3
"""Load claude-md/settings-global.jsonc as the JSON installed to settings.json.

Used by install.sh (first install) and settings_sync_hooks.py. Both must read
the template the same way: if they differed, the sync would see hooks the
install never wrote, or miss hooks it did.

Two transformations:
- `//` comments are stripped per line. This is the same rule install.sh has
  always applied with `sed 's|//.*||'`, so it also cuts a `//` inside a string
  value; the template must not contain one.
- `__HOME__` is replaced by the real home directory. Values under "env" reach
  their subprocess as literal strings, so nothing else expands `~` or
  `${HOME}` for them; the placeholder has to be resolved here, on the machine
  that has a $HOME.

Usage:
    settings_template.py <template.jsonc>

Output and exit status:
    0  the JSON on stdout, two-space indent, trailing newline
    1  the template is missing or not valid JSON after stripping (stderr says why)
    2  usage error
"""

import json
import os
import re
import sys

HOME_PLACEHOLDER = "__HOME__"
COMMENT = re.compile(r"//.*")


def _expand(value, home):
    if isinstance(value, str):
        return value.replace(HOME_PLACEHOLDER, home)
    if isinstance(value, list):
        return [_expand(item, home) for item in value]
    if isinstance(value, dict):
        return {key: _expand(item, home) for key, item in value.items()}
    return value


def load(path):
    """Return the template at `path` as a dict. Raises OSError or ValueError."""
    with open(path, encoding="utf-8") as f:
        text = "".join(COMMENT.sub("", line) for line in f)
    return _expand(json.loads(text), os.path.expanduser("~"))


def dumps(config):
    """Serialize settings the way they are written to settings.json."""
    return json.dumps(config, indent=2) + "\n"


def main():
    if len(sys.argv) != 2:
        print("usage: settings_template.py <template.jsonc>", file=sys.stderr)
        return 2
    try:
        config = load(sys.argv[1])
    except (OSError, ValueError) as exc:
        print(f"settings_template.py: cannot load {sys.argv[1]}: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(dumps(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
