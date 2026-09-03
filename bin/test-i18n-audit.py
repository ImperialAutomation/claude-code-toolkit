#!/usr/bin/env python3
"""
Standalone tests for i18n-audit.py.

Run directly: python3 bin/test-i18n-audit.py
Or via venv: ~/.claude/bin/venv-run.sh python bin/test-i18n-audit.py
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_PATH = Path(__file__).parent / "i18n-audit.py"

spec = importlib.util.spec_from_file_location("i18n_audit", SCRIPT_PATH)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

passed = 0
failed = 0


def check(name, condition):
    global passed, failed
    if condition:
        print(f"PASS: {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        failed += 1


# --- scan_source_files: bare string literals that look like keys ---
#
# A `labelKey: "settings.notifications.emailDigest"` indirection puts the key in
# a data structure and resolves it through t() elsewhere. The key is literally in
# the source, so it is by definition not dead.

def scan_snippet(source: str, filename: str = "Component.tsx"):
    """Write a snippet to a temp source tree and scan it."""
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "src"
        src.mkdir()
        (src / filename).write_text(source, encoding="utf-8")
        return audit.scan_source_files(
            src,
            [".ts", ".tsx"],
            set(audit.DEFAULT_EXCLUDE_DIRS),
            set(audit.DEFAULT_EXCLUDE_FILE_PATTERNS),
        )


result = scan_snippet('const config = { labelKey: "settings.notifications.emailDigest" };')
check(
    "labelKey literal is collected as a literal key",
    "settings.notifications.emailDigest" in result.literal_keys,
)

check(
    "labelKey literal is NOT a t() call site",
    "settings.notifications.emailDigest" not in result.key_locations,
)

result = scan_snippet('import { formatDate } from "./utils/dateHelpers";')
check(
    "import path is not mistaken for a translation key",
    not any(k.startswith("./") for k in result.literal_keys),
)


# --- check_unused: literals suppress the false positive ---

check(
    "key present only as a bare literal is not reported unused",
    audit.check_unused(
        used_keys=set(),
        locale_keys={"settings.notifications.emailDigest"},
        literal_keys={"settings.notifications.emailDigest"},
    )
    == set(),
)

check(
    "key absent from source is still reported unused",
    audit.check_unused(
        used_keys=set(),
        locale_keys={"settings.notifications.emailDigest"},
        literal_keys=set(),
    )
    == {"settings.notifications.emailDigest"},
)


# --- check_missing must NOT gain entries from bare literals ---
#
# A dotted string in source is weak evidence of use, but no evidence at all
# that a key SHOULD exist. Feeding literals into missing would invent keys out
# of filenames, CSS classes and package names.

check(
    "bare literals do not create missing keys",
    audit.check_missing(used_keys=set(), locale_keys=set()) == set(),
)


# --- summary ---

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
