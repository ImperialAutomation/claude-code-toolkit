#!/usr/bin/env python3
"""
Audit i18n translation key usage across a frontend project.

Finds missing keys (used in code but not in locale files), unused keys
(defined in locale files but never referenced in code), and cross-locale
inconsistencies (keys present in one locale but missing from another).

Usage:
  i18n-audit.py [options] [project-dir]
  i18n-audit.py --locale-dir src/i18n/locales --source-dir src
  i18n-audit.py --check missing

Examples:
  i18n-audit.py                          # auto-detect from current directory
  i18n-audit.py /path/to/project         # auto-detect from specified project
  i18n-audit.py --check missing          # only report missing keys
  i18n-audit.py --json                   # output as JSON
"""

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from fnmatch import fnmatch
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

LOCALE_DIR_CANDIDATES = [
    "src/i18n/locales",
    "src/locales",
    "public/locales",
    "locales",
    "src/i18n",
    "src/lang",
    "src/assets/i18n",
    "src/locale",
    "lang",
    "translations",
    "i18n",
]

DEFAULT_EXCLUDE_DIRS = {
    "node_modules", "dist", "build", ".next", "__mocks__", "coverage",
    ".git", ".nuxt", ".output", "__pycache__", ".svelte-kit",
}

DEFAULT_EXCLUDE_FILE_PATTERNS = {"*.test.*", "*.spec.*", "*.stories.*"}

# Translation function patterns — each captures the key string
TRANSLATION_PATTERNS = [
    # t('key') / t("key") — with word boundary to avoid matching e.g.ият(
    re.compile(r'''(?:^|[\s,({=!?:;&|+\[<])t\(\s*['"]([^'"]+)['"]\s*[,)]'''),
    # i18n.t('key')
    re.compile(r'''i18n\.t\(\s*['"]([^'"]+)['"]\s*[,)]'''),
    # $t('key') — vue-i18n
    re.compile(r'''\$t\(\s*['"]([^'"]+)['"]\s*[,)]'''),
    # <Trans i18nKey="key"> — react-i18next component
    re.compile(r'''<Trans\s[^>]*i18nKey\s*=\s*['"]([^'"]+)['"]'''),
]

# Pattern to detect dynamic/template literal keys (not auditable)
DYNAMIC_KEY_PATTERN = re.compile(r'''(?:(?:^|[\s,({=!?:;&|+\[<])t|i18n\.t|\$t)\(\s*`([^`]*\$\{[^`]*)`''')

# Any quoted string in the source. Candidates are filtered by is_key_shaped()
# before they count — this is deliberately broad, because keys reach t() through
# indirection as often as they are passed to it directly.
STRING_LITERAL_PATTERN = re.compile(r'''['"]([^'"\n]+)['"]''')

# Keys look like dotted identifiers: at least two segments of word characters.
# Rejects paths ("./utils/x"), sentences, CSS classes and version strings.
KEY_SHAPE_PATTERN = re.compile(r'^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)+$')


def is_key_shaped(candidate: str) -> bool:
    """Whether a string could be a translation key.

    Shape alone, no locale lookup: the caller intersects with the locale file,
    so a false positive here can only ever suppress an unused-key report for a
    key that literally occurs in the source — which is the intended behaviour.
    """
    return bool(KEY_SHAPE_PATTERN.match(candidate))


def extract_static_prefix(pattern: str) -> Optional[str]:
    """The literal namespace a dynamic key reaches, or None if there is none.

    `admin.users.roles.${role}` resolves at runtime to some key under
    `admin.users.roles.`, so the prefix is everything up to the first `${`.
    Anything after it is unknowable and discarded, including further segments.

    Returns None when the prefix would not name a namespace: a pattern starting
    with the interpolation has no static part, and one whose interpolation does
    not follow a dot (`errorCode${code}`) interpolates inside a segment rather
    than choosing between segments. Both would otherwise yield a prefix that
    matches far more keys than the call site can actually reach.
    """
    static = pattern.split("${", 1)[0]
    if ":" in static:
        static = static.split(":", 1)[1]
    if not static.endswith("."):
        return None
    return static


def dynamic_prefixes(dynamic_keys: List[Tuple[str, str, int]]) -> Set[str]:
    """The set of static prefixes over all detected dynamic call sites."""
    prefixes = set()
    for pattern, _filepath, _lineno in dynamic_keys:
        prefix = extract_static_prefix(pattern)
        if prefix:
            prefixes.add(prefix)
    return prefixes


@dataclass
class ScanResult:
    """What a source scan found.

    `key_locations` holds keys passed to a translation function — strong
    evidence, safe to drive the missing-key check. `literal_keys` holds bare
    key-shaped strings found anywhere — weak evidence of use, strong evidence
    of NOT being dead, so it feeds only the unused check.
    """

    key_locations: Dict[str, List[Tuple[str, int]]] = field(default_factory=dict)
    literal_keys: Set[str] = field(default_factory=set)
    dynamic_keys: List[Tuple[str, str, int]] = field(default_factory=list)


def flatten_json(obj: dict, prefix: str = "") -> Dict[str, str]:
    """Flatten nested JSON into dot-notation keys."""
    result = {}
    for key, value in obj.items():
        full_key = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict):
            result.update(flatten_json(value, full_key))
        else:
            result[full_key] = str(value)
    return result


def detect_locale_dir(project_root: Path) -> Optional[Path]:
    """Try common locale directory patterns."""
    for candidate in LOCALE_DIR_CANDIDATES:
        path = project_root / candidate
        if path.is_dir():
            # Check for JSON files directly or subdirectories with JSON files
            json_files = list(path.glob("*.json"))
            subdirs_with_json = [
                d for d in path.iterdir()
                if d.is_dir() and list(d.glob("*.json"))
            ]
            if json_files or subdirs_with_json:
                return path
    return None


def detect_locale_structure(locale_dir: Path) -> str:
    """Detect flat vs namespaced locale structure.

    Flat: locales/nl.json, locales/en.json
    Namespaced: locales/en/common.json, locales/en/dashboard.json
    """
    json_files = list(locale_dir.glob("*.json"))
    subdirs = [d for d in locale_dir.iterdir() if d.is_dir()]

    if json_files and not subdirs:
        return "flat"
    if subdirs and not json_files:
        # Check if subdirs contain JSON files
        for subdir in subdirs:
            if list(subdir.glob("*.json")):
                return "namespaced"
    # Default: if both exist, prefer flat
    if json_files:
        return "flat"
    return "namespaced"


def load_locales_flat(locale_dir: Path) -> Dict[str, Dict[str, str]]:
    """Load flat locale files (one JSON per locale)."""
    locales = {}
    for json_file in sorted(locale_dir.glob("*.json")):
        try:
            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            locales[json_file.name] = flatten_json(data)
        except (json.JSONDecodeError, OSError) as e:
            print(f"Warning: could not load {json_file}: {e}", file=sys.stderr)
    return locales


def load_locales_namespaced(locale_dir: Path) -> Dict[str, Dict[str, str]]:
    """Load namespaced locale files (subdirectory per locale)."""
    locales = {}
    for subdir in sorted(locale_dir.iterdir()):
        if not subdir.is_dir():
            continue
        locale_name = subdir.name
        combined_keys = {}
        for json_file in sorted(subdir.glob("*.json")):
            namespace = json_file.stem
            try:
                with open(json_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                flat = flatten_json(data, prefix=namespace)
                combined_keys.update(flat)
            except (json.JSONDecodeError, OSError) as e:
                print(f"Warning: could not load {json_file}: {e}", file=sys.stderr)
        if combined_keys:
            locales[locale_name] = combined_keys
    return locales


def detect_extensions(project_root: Path) -> List[str]:
    """Detect source file extensions based on project contents."""
    src_dir = project_root / "src"
    search_dir = src_dir if src_dir.is_dir() else project_root

    has_tsx = any(True for _ in _limited_rglob(search_dir, "*.tsx", 1))
    has_vue = any(True for _ in _limited_rglob(search_dir, "*.vue", 1))
    has_svelte = any(True for _ in _limited_rglob(search_dir, "*.svelte", 1))

    if has_tsx:
        return [".ts", ".tsx", ".js", ".jsx"]
    if has_vue:
        return [".vue", ".ts", ".js"]
    if has_svelte:
        return [".svelte", ".ts", ".js"]
    return [".js", ".jsx", ".ts", ".tsx", ".vue", ".svelte"]


def _limited_rglob(directory: Path, pattern: str, limit: int):
    """Yield at most `limit` matches from rglob, skipping excluded dirs."""
    count = 0
    for match in directory.rglob(pattern):
        # Skip excluded directories
        if any(part in DEFAULT_EXCLUDE_DIRS for part in match.parts):
            continue
        yield match
        count += 1
        if count >= limit:
            return


def detect_source_dir(project_root: Path) -> Path:
    """Detect source directory."""
    src = project_root / "src"
    if src.is_dir():
        return src
    return project_root


def select_reference_locale(locales: Dict[str, Dict[str, str]]) -> str:
    """Select the locale with the most keys as reference."""
    return max(locales, key=lambda name: len(locales[name]))


def scan_source_files(
    source_dir: Path,
    extensions: List[str],
    exclude_dirs: Set[str],
    exclude_file_patterns: Set[str],
) -> ScanResult:
    """Scan source files for translation key usage."""
    result = ScanResult()
    key_locations = result.key_locations
    dynamic_keys = result.dynamic_keys

    for root, dirs, files in os.walk(source_dir):
        # Prune excluded directories
        dirs[:] = [d for d in dirs if d not in exclude_dirs]

        for filename in files:
            # Check extension
            if not any(filename.endswith(ext) for ext in extensions):
                continue

            # Check exclude patterns
            if any(fnmatch(filename, pat) for pat in exclude_file_patterns):
                continue

            filepath = os.path.join(root, filename)
            try:
                with open(filepath, "r", encoding="utf-8") as f:
                    content = f.read()
            except (OSError, UnicodeDecodeError):
                continue

            for lineno, line in enumerate(content.splitlines(), 1):
                # Check for dynamic keys
                for match in DYNAMIC_KEY_PATTERN.finditer(line):
                    dynamic_keys.append((match.group(1), filepath, lineno))

                # Any key-shaped string literal, wherever it sits. Covers the
                # labelKey/titleKey/messageKey indirection where the key is
                # stored in a config object and resolved by t() elsewhere.
                for match in STRING_LITERAL_PATTERN.finditer(line):
                    candidate = match.group(1)
                    if is_key_shaped(candidate):
                        result.literal_keys.add(candidate)

                # Check for static keys
                for pattern in TRANSLATION_PATTERNS:
                    for match in pattern.finditer(line):
                        key = match.group(1)

                        # Handle namespace:key syntax (i18next)
                        if ":" in key:
                            # Strip namespace prefix for lookup
                            key = key.split(":", 1)[1]

                        # Validate key format to reduce false positives:
                        # - Must contain at least one dot
                        # - Must not contain spaces (real keys use camelCase/dots)
                        # - Must match dotted identifier pattern
                        if not is_key_shaped(key):
                            continue

                        if key not in key_locations:
                            key_locations[key] = []
                        key_locations[key].append((filepath, lineno))

    return result


# CLDR plural categories, as i18next suffixes them. A key with a `count`
# option is looked up as `<key>_<category>` at runtime, so the bare key never
# appears in the locale file and a literal comparison reports it missing.
PLURAL_SUFFIXES = ("zero", "one", "two", "few", "many", "other")


def check_missing(
    used_keys: Set[str], locale_keys: Set[str]
) -> Set[str]:
    """Find keys used in code but not in locale.

    A pluralised key resolves through its CLDR suffixes rather than its bare
    form: `t("photos.count", {count})` reads `photos.count_one` /
    `photos.count_other` and never `photos.count` itself. Treating the bare key
    as missing is a false positive, and one that cannot be silenced without
    duplicating the key — so any suffixed variant satisfies the bare form.
    """
    pluralised = {
        key[: -(len(suffix) + 1)]
        for key in locale_keys
        for suffix in PLURAL_SUFFIXES
        if key.endswith(f"_{suffix}")
    }
    return used_keys - locale_keys - pluralised


def check_unused(
    used_keys: Set[str], locale_keys: Set[str], literal_keys: Set[str]
) -> Set[str]:
    """Find keys in locale but not used in code.

    `literal_keys` are key-shaped strings found anywhere in the source, not just
    inside a t() call. A key that occurs literally in the code cannot be dead —
    it reaches t() through a config object, a route table or a props chain — so
    reporting it as unused invites deleting a working translation.

    The plural handling mirrors `check_missing`: the code calls the bare key, so
    `<key>_one` and `<key>_other` never appear as "used" and every pluralised
    entry would be reported as dead translation.
    """
    referenced = used_keys | literal_keys
    return {
        key
        for key in locale_keys - referenced
        if not (
            any(key.endswith(f"_{suffix}") for suffix in PLURAL_SUFFIXES)
            and key.rsplit("_", 1)[0] in referenced
        )
    }


def split_undeterminable(
    unused: Set[str], prefixes: Set[str]
) -> Tuple[Set[str], Set[str]]:
    """Split unused keys into genuinely dead ones and unresolvable ones.

    A key under a prefix the code interpolates into is reachable at runtime; the
    audit simply cannot say from which call. Reporting it alongside dead keys is
    what makes the unused list unsafe to act on, so it becomes its own bucket.

    Prefixes end in a dot, so matching is on the segment boundary: the
    `admin.users.` prefix covers `admin.users.roles.owner` but not the unrelated
    sibling `admin.usersOverview`.
    """
    undeterminable = {
        key for key in unused if any(key.startswith(prefix) for prefix in prefixes)
    }
    return unused - undeterminable, undeterminable


def check_consistency(
    locales: Dict[str, Dict[str, str]], reference: str
) -> Dict[str, Set[str]]:
    """Find keys missing from non-reference locales."""
    ref_keys = set(locales[reference].keys())
    result = {}
    for name, keys in locales.items():
        if name == reference:
            continue
        missing = ref_keys - set(keys.keys())
        if missing:
            result[name] = missing
    return result


def _covering_prefix(key: str, prefixes: Set[str]) -> Optional[str]:
    """The dynamic prefix that makes this key unresolvable.

    Longest match wins, so a key under both `admin.` and `admin.users.` is
    attributed to the call site that actually reaches it.
    """
    matches = [prefix for prefix in prefixes if key.startswith(prefix)]
    return max(matches, key=len) if matches else None


def group_by_prefix(keys: Set[str]) -> Dict[str, List[str]]:
    """Group keys by their first dot-segment."""
    groups: Dict[str, List[str]] = {}
    for key in sorted(keys):
        prefix = key.split(".")[0]
        if prefix not in groups:
            groups[prefix] = []
        groups[prefix].append(key)
    return groups


def format_plain_text(
    config: dict,
    missing: Set[str],
    unused: Set[str],
    undeterminable: Set[str],
    consistency: Dict[str, Set[str]],
    key_locations: Dict[str, List[Tuple[str, int]]],
    dynamic_keys: List[Tuple[str, str, int]],
    checks: List[str],
    project_root: str,
) -> str:
    """Format results as plain text."""
    lines = []
    lines.append("i18n Audit Report")
    lines.append("=" * 50)
    lines.append(f"Project:          {config['project']}")
    lines.append(f"Locale directory: {config['locale_dir']}")
    lines.append(f"Reference locale: {config['reference']} ({config['ref_key_count']} keys)")
    lines.append(f"Locales found:    {', '.join(config['locales'])}")
    lines.append(f"Source directory:  {config['source_dir']}")
    lines.append(f"Files scanned:    {config['files_scanned']}")
    lines.append(f"Extensions:       {', '.join(config['extensions'])}")
    lines.append("")

    total_issues = 0

    if "missing" in checks or "all" in checks:
        lines.append(f"── Missing Keys ({len(missing)}) " + "─" * 30)
        if missing:
            lines.append("Keys used in source code but not in reference locale:")
            lines.append("")
            for prefix, keys in group_by_prefix(missing).items():
                lines.append(f"  {prefix}:")
                for key in keys:
                    locs = key_locations.get(key, [])
                    if locs:
                        # Show first location, relative to project root
                        filepath, lineno = locs[0]
                        rel_path = os.path.relpath(filepath, project_root)
                        extra = f"  (+{len(locs)-1} more)" if len(locs) > 1 else ""
                        lines.append(f"    {key:<45} {rel_path}:{lineno}{extra}")
                    else:
                        lines.append(f"    {key}")
            total_issues += len(missing)
        else:
            lines.append("  No missing keys found.")
        lines.append("")

    if "unused" in checks or "all" in checks:
        lines.append(f"── Unused Keys ({len(unused)}) " + "─" * 30)
        if dynamic_keys:
            lines.append(
                f"WARNING: {len(dynamic_keys)} dynamic key(s) detected — this list "
                "cannot be fully reliable."
            )
            lines.append(
                "         Verify a key is truly dead before deleting it."
            )
            lines.append("")
        if unused:
            lines.append("Keys in reference locale but not found in source code:")
            lines.append("")
            for prefix, keys in group_by_prefix(unused).items():
                lines.append(f"  {prefix}:")
                for key in keys:
                    lines.append(f"    {key}")
            total_issues += len(unused)
        else:
            lines.append("  No unused keys found.")
        lines.append("")

        lines.append(f"── Undeterminable Keys ({len(undeterminable)}) " + "─" * 20)
        if undeterminable:
            lines.append(
                "Unreferenced keys that a dynamic call site can still reach. "
                "Not dead — not counted as issues."
            )
            lines.append("")
            prefixes = dynamic_prefixes(dynamic_keys)
            counts: Dict[str, int] = {}
            for key in undeterminable:
                covering = _covering_prefix(key, prefixes)
                if covering:
                    counts[covering] = counts.get(covering, 0) + 1
            for prefix in sorted(counts):
                lines.append(f"  {prefix}*  ({counts[prefix]} key(s))")
            lines.append("")
            lines.append("  Use --json for the full key list.")
        else:
            lines.append("  None.")
        lines.append("")

    if "consistency" in checks or "all" in checks:
        consistency_total = sum(len(v) for v in consistency.values())
        lines.append(f"── Cross-Locale Consistency " + "─" * 23)
        if consistency:
            ref = config["reference"]
            lines.append(f"Keys in {ref} missing from other locales:")
            lines.append("")
            for locale_name in sorted(consistency.keys()):
                missing_keys = consistency[locale_name]
                lines.append(f"  {locale_name}: {len(missing_keys)} missing key(s)")
                # Show first few
                for key in sorted(missing_keys)[:5]:
                    lines.append(f"    {key}")
                if len(missing_keys) > 5:
                    lines.append(f"    ... and {len(missing_keys) - 5} more")
            total_issues += consistency_total
        else:
            lines.append("  All locales are consistent.")
        lines.append("")

    if dynamic_keys and ("missing" in checks or "all" in checks):
        lines.append(f"── Dynamic Keys ({len(dynamic_keys)}) " + "─" * 27)
        lines.append("Keys using template literals (cannot audit statically):")
        lines.append("")
        for pattern, filepath, lineno in dynamic_keys[:10]:
            rel_path = os.path.relpath(filepath, project_root)
            lines.append(f"  `{pattern}`  {rel_path}:{lineno}")
        if len(dynamic_keys) > 10:
            lines.append(f"  ... and {len(dynamic_keys) - 10} more")
        lines.append("")

    lines.append("── Summary " + "─" * 39)
    parts = []
    if "missing" in checks or "all" in checks:
        parts.append(f"Missing: {len(missing)}")
    if "unused" in checks or "all" in checks:
        parts.append(f"Unused: {len(unused)}")
        parts.append(f"Undeterminable: {len(undeterminable)}")
    if "consistency" in checks or "all" in checks:
        consistency_total = sum(len(v) for v in consistency.values())
        parts.append(f"Inconsistent: {consistency_total}")
    lines.append(" | ".join(parts))

    if total_issues == 0:
        lines.append("\nResult: CLEAN")
    else:
        lines.append(f"\nResult: {total_issues} ISSUE(S) FOUND")

    return "\n".join(lines)


def format_json_output(
    config: dict,
    missing: Set[str],
    unused: Set[str],
    undeterminable: Set[str],
    consistency: Dict[str, Set[str]],
    key_locations: Dict[str, List[Tuple[str, int]]],
    dynamic_keys: List[Tuple[str, str, int]],
    checks: List[str],
    project_root: str,
) -> str:
    """Format results as JSON."""
    result = {"config": config}

    if "missing" in checks or "all" in checks:
        result["missing"] = [
            {
                "key": key,
                "locations": [
                    {"file": os.path.relpath(f, project_root), "line": l}
                    for f, l in key_locations.get(key, [])
                ],
            }
            for key in sorted(missing)
        ]

    if "unused" in checks or "all" in checks:
        result["unused"] = [{"key": key} for key in sorted(unused)]
        result["undeterminable"] = [
            {"key": key, "prefix": _covering_prefix(key, dynamic_prefixes(dynamic_keys))}
            for key in sorted(undeterminable)
        ]

    if "consistency" in checks or "all" in checks:
        result["consistency"] = {
            name: sorted(keys) for name, keys in sorted(consistency.items())
        }

    result["dynamicKeys"] = [
        {
            "pattern": pattern,
            "file": os.path.relpath(filepath, project_root),
            "line": lineno,
        }
        for pattern, filepath, lineno in dynamic_keys
    ]

    total_issues = 0
    if "missing" in checks or "all" in checks:
        total_issues += len(missing)
    if "unused" in checks or "all" in checks:
        total_issues += len(unused)
    if "consistency" in checks or "all" in checks:
        total_issues += sum(len(v) for v in consistency.values())

    result["summary"] = {
        "missingCount": len(missing) if ("missing" in checks or "all" in checks) else None,
        "unusedCount": len(unused) if ("unused" in checks or "all" in checks) else None,
        "consistencyIssueCount": (
            sum(len(v) for v in consistency.values())
            if ("consistency" in checks or "all" in checks)
            else None
        ),
        "undeterminableCount": (
            len(undeterminable) if ("unused" in checks or "all" in checks) else None
        ),
        "dynamicKeyCount": len(dynamic_keys),
        "totalIssues": total_issues,
        "status": "CLEAN" if total_issues == 0 else "ISSUES_FOUND",
    }

    return json.dumps(result, indent=2, ensure_ascii=False)


def count_scanned_files(
    source_dir: Path,
    extensions: List[str],
    exclude_dirs: Set[str],
    exclude_file_patterns: Set[str],
) -> int:
    """Count how many files would be scanned."""
    count = 0
    for root, dirs, files in os.walk(source_dir):
        dirs[:] = [d for d in dirs if d not in exclude_dirs]
        for filename in files:
            if not any(filename.endswith(ext) for ext in extensions):
                continue
            if any(fnmatch(filename, pat) for pat in exclude_file_patterns):
                continue
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(
        description="Audit i18n translation key usage across a frontend project.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                              Auto-detect from current directory
  %(prog)s /path/to/project             Auto-detect from specified project
  %(prog)s --locale-dir src/i18n/locales --source-dir src
  %(prog)s --check missing              Only report missing keys
  %(prog)s --json                       Output as JSON
        """,
    )
    parser.add_argument(
        "project_dir",
        nargs="?",
        default=os.getcwd(),
        help="Project root directory (default: current directory)",
    )
    parser.add_argument(
        "--locale-dir",
        help="Path to locale directory (relative to project root, or absolute)",
    )
    parser.add_argument(
        "--source-dir",
        help="Path to source directory to scan (relative to project root, or absolute)",
    )
    parser.add_argument(
        "--reference-locale",
        help="Reference locale filename (default: locale with most keys)",
    )
    parser.add_argument(
        "--extensions",
        help="Comma-separated file extensions to scan (e.g. .ts,.tsx,.vue)",
    )
    parser.add_argument(
        "--check",
        choices=["missing", "unused", "consistency", "all"],
        default="all",
        help="Which check(s) to run (default: all)",
    )
    parser.add_argument(
        "--exclude-dirs",
        help="Comma-separated directories to skip (added to defaults)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output in JSON format",
    )

    args = parser.parse_args()

    project_root = Path(args.project_dir).resolve()
    if not project_root.is_dir():
        print(f"Error: project directory not found: {project_root}", file=sys.stderr)
        sys.exit(2)

    # Resolve locale directory
    if args.locale_dir:
        locale_dir = Path(args.locale_dir)
        if not locale_dir.is_absolute():
            locale_dir = project_root / locale_dir
        if not locale_dir.is_dir():
            print(f"Error: locale directory not found: {locale_dir}", file=sys.stderr)
            sys.exit(2)
    else:
        locale_dir = detect_locale_dir(project_root)
        if locale_dir is None:
            print(
                "Error: could not auto-detect locale directory. "
                "Use --locale-dir to specify.",
                file=sys.stderr,
            )
            sys.exit(2)

    # Detect structure and load locales
    structure = detect_locale_structure(locale_dir)
    if structure == "flat":
        locales = load_locales_flat(locale_dir)
    else:
        locales = load_locales_namespaced(locale_dir)

    if not locales:
        print(f"Error: no locale files found in {locale_dir}", file=sys.stderr)
        sys.exit(2)

    # Select reference locale
    if args.reference_locale:
        if args.reference_locale not in locales:
            print(
                f"Error: reference locale '{args.reference_locale}' not found. "
                f"Available: {', '.join(sorted(locales.keys()))}",
                file=sys.stderr,
            )
            sys.exit(2)
        reference = args.reference_locale
    else:
        reference = select_reference_locale(locales)

    # Resolve source directory
    if args.source_dir:
        source_dir = Path(args.source_dir)
        if not source_dir.is_absolute():
            source_dir = project_root / source_dir
        if not source_dir.is_dir():
            print(f"Error: source directory not found: {source_dir}", file=sys.stderr)
            sys.exit(2)
    else:
        source_dir = detect_source_dir(project_root)

    # Determine extensions
    if args.extensions:
        extensions = [
            ext if ext.startswith(".") else f".{ext}"
            for ext in args.extensions.split(",")
        ]
    else:
        extensions = detect_extensions(project_root)

    # Build exclude sets
    exclude_dirs = set(DEFAULT_EXCLUDE_DIRS)
    if args.exclude_dirs:
        exclude_dirs.update(args.exclude_dirs.split(","))
    exclude_file_patterns = set(DEFAULT_EXCLUDE_FILE_PATTERNS)

    # Scan source files
    scan = scan_source_files(
        source_dir, extensions, exclude_dirs, exclude_file_patterns
    )
    key_locations = scan.key_locations
    dynamic_keys = scan.dynamic_keys
    used_keys = set(key_locations.keys())
    ref_keys = set(locales[reference].keys())

    # Count scanned files
    files_scanned = count_scanned_files(
        source_dir, extensions, exclude_dirs, exclude_file_patterns
    )

    # Run checks
    checks = [args.check]
    missing = check_missing(used_keys, ref_keys) if args.check in ("missing", "all") else set()
    unused = (
        check_unused(used_keys, ref_keys, scan.literal_keys)
        if args.check in ("unused", "all")
        else set()
    )
    consistency = (
        check_consistency(locales, reference)
        if args.check in ("consistency", "all")
        else {}
    )

    # Dynamic call sites are collected regardless of --check, so the unused list
    # is filtered the same way whichever checks are requested.
    prefixes = dynamic_prefixes(dynamic_keys)
    unused, undeterminable = split_undeterminable(unused, prefixes)

    # Build config info
    rel_locale_dir = os.path.relpath(locale_dir, project_root)
    rel_source_dir = os.path.relpath(source_dir, project_root)
    config = {
        "project": str(project_root),
        "locale_dir": rel_locale_dir,
        "reference": reference,
        "ref_key_count": len(ref_keys),
        "locales": sorted(locales.keys()),
        "source_dir": rel_source_dir,
        "files_scanned": files_scanned,
        "extensions": extensions,
    }

    # Output
    if args.json_output:
        print(format_json_output(
            config, missing, unused, undeterminable, consistency,
            key_locations, dynamic_keys, checks, str(project_root),
        ))
    else:
        print(format_plain_text(
            config, missing, unused, undeterminable, consistency,
            key_locations, dynamic_keys, checks, str(project_root),
        ))

    # Exit code
    total_issues = len(missing) + len(unused) + sum(len(v) for v in consistency.values())
    sys.exit(1 if total_issues > 0 else 0)


if __name__ == "__main__":
    main()
