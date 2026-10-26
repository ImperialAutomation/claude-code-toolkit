#!/usr/bin/env python3
"""Add hooks from settings-global.jsonc that are missing in a live settings.json.

install.sh copies the template only when ~/.claude/settings.json does not exist,
so every hook added to the template after the first install never reaches the
live file. This adds those hooks and touches nothing else.

A hook entry is identified by (event, matcher, command), with the template's
command compared after __HOME__ expansion. Groups are not compared as a whole:
the live file need not mirror the template's grouping (two template groups can
share one live group), and comparing groups would report hooks that are there.

Only additions. A live hook that is not in the template (a user's own, or one
the template dropped) stays, and fields of an existing entry (`timeout`, ...)
are not compared. A missing entry is copied verbatim into the first live group
of the same event and matcher, or into a new group appended to that event.

Writes only when something is missing: the original bytes go to a new
<settings>.<YYYYmmdd-HHMMSS>.bak (never an existing file), and the new file
replaces the old one atomically with the same mode.
The output is two-space-indented JSON, so a hand-formatted file is normalized on
its first write; key order is kept.

Usage:
    settings_sync_hooks.py [--dry-run] [--settings PATH] [--template PATH]

Exit status:
    0  up to date, hooks added, or (--dry-run) the missing ones reported
    1  the live settings or the template could not be read or are malformed
    2  usage error
"""

import argparse
import copy
import itertools
import json
import os
import stat
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_template  # noqa: E402

DEFAULT_SETTINGS = "~/.claude/settings.json"
DEFAULT_TEMPLATE = Path(__file__).resolve().parents[2] / "claude-md" / "settings-global.jsonc"
BACKUP_TIMESTAMP = "%Y%m%d-%H%M%S"
BACKUP_SUFFIX = ".bak"
NO_MATCHER_LABEL = "no matcher"


class Malformed(Exception):
    pass


def _groups(config, source):
    """Yield (event, group) for every hook group, refusing a malformed shape."""
    hooks = config.get("hooks", {})
    if not isinstance(hooks, dict):
        raise Malformed(f"{source}: \"hooks\" is not an object")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise Malformed(f"{source}: hooks.{event} is not a list")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
                raise Malformed(f"{source}: a hooks.{event} group is malformed")
            yield event, group


def _key(event, group, hook):
    return (event, group.get("matcher"), hook.get("command"))


def find_missing(template, live):
    """Return [(event, template_group, hook)] for template entries absent live."""
    present = {
        _key(event, group, hook)
        for event, group in _groups(live, "settings")
        for hook in group.get("hooks", [])
    }
    missing = []
    for event, group in _groups(template, "template"):
        for hook in group.get("hooks", []):
            key = _key(event, group, hook)
            if key not in present:
                present.add(key)
                missing.append((event, group, hook))
    return missing


def merge(live, missing):
    """Add the missing entries to `live` in place."""
    hooks = live.setdefault("hooks", {})
    for event, template_group, hook in missing:
        groups = hooks.setdefault(event, [])
        matcher = template_group.get("matcher")
        target = next((g for g in groups if g.get("matcher") == matcher), None)
        if target is None:
            target = {k: copy.deepcopy(v) for k, v in template_group.items() if k != "hooks"}
            target["hooks"] = []
            groups.append(target)
        target.setdefault("hooks", []).append(copy.deepcopy(hook))


def describe(event, group, hook):
    matcher = group.get("matcher")
    return f"{event} [{NO_MATCHER_LABEL if matcher is None else matcher}] {hook.get('command')}"


def _write_atomically(path, text, mode):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=f".{os.path.basename(path)}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def _write_backup(path, original):
    """Write `original` to a new <path>.<timestamp>.bak and return its name.

    Never replaces an existing file: a plain <path>.bak may be a backup the user
    made by hand, and two syncs in one second must not share a name.
    """
    stem = f"{path}.{time.strftime(BACKUP_TIMESTAMP)}"
    for attempt in itertools.count():
        backup = f"{stem}{'' if attempt == 0 else f'-{attempt}'}{BACKUP_SUFFIX}"
        try:
            with open(backup, "xb") as f:
                f.write(original)
            return backup
        except FileExistsError:
            continue


def _load_live(path):
    try:
        with open(path, "rb") as f:
            original = f.read()
    except FileNotFoundError:
        raise Malformed(f"{path} does not exist; run install.sh for a first install")
    except OSError as exc:
        raise Malformed(f"cannot read {path}: {exc}")
    try:
        live = json.loads(original)
    except ValueError as exc:
        raise Malformed(f"{path} is not valid JSON: {exc}")
    if not isinstance(live, dict):
        raise Malformed(f"{path} is not a JSON object")
    return original, live


def main(argv=None):
    parser = argparse.ArgumentParser(description="Add missing template hooks to settings.json.")
    parser.add_argument("--dry-run", action="store_true", help="report, write nothing")
    parser.add_argument("--settings", default=DEFAULT_SETTINGS)
    parser.add_argument("--template", default=str(DEFAULT_TEMPLATE))
    args = parser.parse_args(argv)

    # A symlinked settings.json is followed, so the write replaces its target
    # rather than turning the link into a file.
    settings = os.path.realpath(os.path.expanduser(args.settings))
    try:
        template = settings_template.load(args.template)
        original, live = _load_live(settings)
        missing = find_missing(template, live)
    except (OSError, ValueError) as exc:
        print(f"settings-sync-hooks: cannot load template {args.template}: {exc}", file=sys.stderr)
        return 1
    except Malformed as exc:
        print(f"settings-sync-hooks: {exc}", file=sys.stderr)
        return 1

    if not missing:
        print(f"settings hooks up to date: {settings}")
        return 0

    verb = "would add" if args.dry_run else "added"
    for entry in missing:
        print(f"{verb}: {describe(*entry)}")
    if args.dry_run:
        return 0

    merge(live, missing)
    mode = stat.S_IMODE(os.stat(settings).st_mode)
    backup = _write_backup(settings, original)
    _write_atomically(settings, settings_template.dumps(live), mode)
    print(f"added {len(missing)} hook(s) to {settings} (backup: {backup})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
