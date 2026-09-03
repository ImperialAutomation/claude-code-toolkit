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


# --- extract_static_prefix: the part of a dynamic key that IS knowable ---
#
# `t(`admin.users.roles.${role}`)` cannot be resolved statically, but everything
# before the first `${` is a literal namespace. That prefix is what tells us
# which locale keys the call reaches.

check(
    "static prefix is everything before the first interpolation",
    audit.extract_static_prefix("admin.users.roles.${role}")
    == "admin.users.roles.",
)

check(
    "trailing segment after the interpolation is ignored",
    audit.extract_static_prefix("profile.types.${type}.label") == "profile.types.",
)

check(
    "i18next namespace prefix is stripped like elsewhere",
    audit.extract_static_prefix("common:admin.users.roles.${role}")
    == "admin.users.roles.",
)

# A pattern that interpolates from the very start has no static part at all.
# Returning "" would match every key in the locale and silently empty the
# unused report, so it must yield nothing.
check(
    "leading interpolation yields no usable prefix",
    audit.extract_static_prefix("${namespace}.roles.admin") is None,
)

check(
    "prefix of a single segment is still usable",
    audit.extract_static_prefix("roles.${role}") == "roles.",
)

# `t(`errors.${code}`)` names a real namespace; `t(`${a}${b}`)` does not.
check(
    "interpolation not preceded by a dot yields no prefix",
    audit.extract_static_prefix("errorCode${code}") is None,
)


# --- dynamic_prefixes: the set over all detected dynamic call sites ---

check(
    "prefixes are collected across call sites and deduplicated",
    audit.dynamic_prefixes(
        [
            ("admin.users.roles.${role}", "src/UserTable.tsx", 42),
            ("admin.users.roles.${r}", "src/RoleBadge.tsx", 17),
            ("profile.types.${profile.type}", "src/ProfileCard.tsx", 88),
            ("${ns}.whatever", "src/Dynamic.tsx", 3),
        ]
    )
    == {"admin.users.roles.", "profile.types."},
)


# --- split_undeterminable: unused keys a dynamic call site could reach ---
#
# The audit already knows `admin.users.roles.${role}` exists. Every key under
# that prefix is reachable at runtime, so listing it as unused hands the reader
# a cleanup list that deletes working translations.

unused, undeterminable = audit.split_undeterminable(
    {
        "admin.users.roles.moderator",
        "admin.users.roles.owner",
        "admin.users.deletedColumnHeader",
        "profile.types.solo",
    },
    {"admin.users.roles.", "profile.types."},
)

check(
    "keys under a detected prefix move to undeterminable",
    undeterminable
    == {"admin.users.roles.moderator", "admin.users.roles.owner", "profile.types.solo"},
)

check(
    "a key outside every prefix stays unused",
    unused == {"admin.users.deletedColumnHeader"},
)

check(
    "no prefixes leaves the unused set untouched",
    audit.split_undeterminable({"a.b", "c.d"}, set()) == ({"a.b", "c.d"}, set()),
)

# The prefix ends in a dot, so `admin.usersOverview` must not be swallowed by
# the `admin.users.` prefix through a plain startswith on a dotless boundary.
check(
    "a sibling key sharing a text prefix is not swallowed",
    audit.split_undeterminable({"admin.usersOverview"}, {"admin.users."})
    == ({"admin.usersOverview"}, set()),
)


# --- end-to-end: a dynamic prefix must not produce issues or a failing exit ---


def run_audit(locale: dict, sources: dict, *extra_args):
    """Run the audit as a subprocess over a throwaway project."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        locale_dir = root / "src" / "i18n" / "locales"
        locale_dir.mkdir(parents=True)
        (locale_dir / "nl.json").write_text(
            json.dumps(locale, ensure_ascii=False), encoding="utf-8"
        )
        for name, body in sources.items():
            path = root / "src" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SCRIPT_PATH), str(root), *extra_args],
            capture_output=True,
            text=True,
        )


DYNAMIC_LOCALE = {
    "admin": {
        "users": {
            "roles": {
                "moderator": "Moderator",
                "owner": "Eigenaar",
                "guest": "Gast",
            },
            "title": "Gebruikersbeheer",
        }
    }
}

DYNAMIC_SOURCE = {
    "RoleBadge.tsx": (
        "import { useTranslation } from 'react-i18next';\n"
        "export function RoleBadge({ role }: { role: string }) {\n"
        "  const { t } = useTranslation();\n"
        "  return <span>{t(`admin.users.roles.${role}`)}</span>;\n"
        "}\n"
    ),
    "UsersPage.tsx": (
        "import { useTranslation } from 'react-i18next';\n"
        "export function UsersPage() {\n"
        "  const { t } = useTranslation();\n"
        "  return <h1>{t('admin.users.title')}</h1>;\n"
        "}\n"
    ),
}

proc = run_audit(DYNAMIC_LOCALE, DYNAMIC_SOURCE, "--json")
report = json.loads(proc.stdout)

check(
    "no key under the dynamic prefix is reported unused",
    [entry["key"] for entry in report["unused"]] == [],
)

check(
    "those keys are reported as undeterminable instead",
    [entry["key"] for entry in report["undeterminable"]]
    == ["admin.users.roles.guest", "admin.users.roles.moderator", "admin.users.roles.owner"],
)

check(
    "undeterminable keys do not count as issues",
    report["summary"]["totalIssues"] == 0
    and report["summary"]["unusedCount"] == 0
    and report["summary"]["undeterminableCount"] == 3,
)

check(
    "an unresolvable key does not fail the exit code",
    proc.returncode == 0,
)

# A genuinely dead key must still be reported, or the fix has simply silenced
# the whole check.
proc = run_audit(
    {**DYNAMIC_LOCALE, "checkout": {"abandonedBasketNotice": "Je mandje wacht"}},
    DYNAMIC_SOURCE,
    "--json",
)
report = json.loads(proc.stdout)

check(
    "a dead key outside the dynamic prefix is still reported unused",
    [entry["key"] for entry in report["unused"]] == ["checkout.abandonedBasketNotice"]
    and report["summary"]["totalIssues"] == 1
    and proc.returncode == 1,
)


# --- text report: the reader must be told the unused list is not reliable ---

proc = run_audit(DYNAMIC_LOCALE, DYNAMIC_SOURCE)
text = proc.stdout

check(
    "unused block carries a warning while dynamic keys exist",
    "WARNING: 1 dynamic key(s) detected" in text,
)

check(
    "undeterminable keys get their own section with the covering prefix",
    "── Undeterminable Keys (3)" in text and "admin.users.roles.*  (3 key(s))" in text,
)

check(
    "summary reports the undeterminable count separately from unused",
    "Unused: 0 | Undeterminable: 3" in text and "Result: CLEAN" in text,
)

# Without dynamic keys the warning must be absent, or it becomes noise that
# readers learn to ignore.
proc = run_audit(
    {"checkout": {"abandonedBasketNotice": "Je mandje wacht"}},
    {
        "Cart.tsx": (
            "import { useTranslation } from 'react-i18next';\n"
            "export function Cart() {\n"
            "  const { t } = useTranslation();\n"
            "  return <p>{t('checkout.otherNotice')}</p>;\n"
            "}\n"
        )
    },
)

check(
    "no warning when the project has no dynamic keys",
    "WARNING:" not in proc.stdout and "── Undeterminable Keys (0)" in proc.stdout,
)


# --- dynamic key listing: truncating hides what cannot be verified by hand ---

MANY_DYNAMIC_SOURCE = {
    f"Widget{n}.tsx": (
        "import { useTranslation } from 'react-i18next';\n"
        f"export function Widget{n}() {{\n"
        "  const { t } = useTranslation();\n"
        f"  return <span>{{t(`widget.section{n}.${{key}}`)}}</span>;\n"
        "}\n"
    )
    for n in range(15)
}
MANY_DYNAMIC_LOCALE = {
    "widget": {f"section{n}": {"label": f"Label {n}"} for n in range(15)}
}

proc = run_audit(MANY_DYNAMIC_LOCALE, MANY_DYNAMIC_SOURCE)

check(
    "every dynamic prefix is listed by default",
    all(f"widget.section{n}." in proc.stdout for n in range(15))
    and "more" not in proc.stdout,
)

proc = run_audit(MANY_DYNAMIC_LOCALE, MANY_DYNAMIC_SOURCE, "--dynamic-limit", "5")
shown = sum(1 for n in range(15) if f"`widget.section{n}." in proc.stdout)

check(
    "--dynamic-limit caps the listing and says how many were hidden",
    shown == 5 and "... and 10 more" in proc.stdout,
)

proc = run_audit(MANY_DYNAMIC_LOCALE, MANY_DYNAMIC_SOURCE, "--dynamic-limit", "5", "--json")
report = json.loads(proc.stdout)

check(
    "--json ignores the limit and stays complete",
    len(report["dynamicKeys"]) == 15,
)


# --- summary ---

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
