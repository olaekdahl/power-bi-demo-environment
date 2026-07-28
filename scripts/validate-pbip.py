#!/usr/bin/env python3
"""
Validate a generated PBIR report against Microsoft's published JSON schemas.

This is the whole reason for moving off report.json. PBIR-Legacy is undocumented
and unvalidatable, so a wrong property shape could only be discovered by opening
the report on the VM and screenshotting it - a five-minute round trip per guess,
with silent failure as the usual outcome (a discarded `objects` entry produces no
error at all). Every PBIR file declares a `$schema`, so the same mistakes are
caught here in about a second.

Schemas are fetched once and cached under scripts/schemas/ (gitignored), so
repeat runs work offline.

Usage:
    python validate-pbip.py powerbi
    python validate-pbip.py powerbi --refresh    # re-download cached schemas
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
    from referencing import Registry, Resource
except ImportError:
    sys.exit("Missing dependencies. Install with:  pip install jsonschema referencing")

CACHE = Path(__file__).resolve().parent / "schemas"
UA = {"User-Agent": "pl300-demo-validate/1.0"}


def cache_path(uri):
    """A filesystem-safe cache name for a schema URI."""
    return CACHE / (uri.split("://", 1)[-1].replace("/", "_"))


def fetch_schema(uri, refresh=False):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = cache_path(uri)
    if path.exists() and not refresh:
        return json.loads(path.read_text(encoding="utf-8"))
    req = urllib.request.Request(uri, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read().decode("utf-8")
    path.write_text(body, encoding="utf-8")
    return json.loads(body)


def make_registry(refresh=False):
    """A referencing Registry that pulls (and caches) $ref targets on demand."""
    def retrieve(uri):
        return Resource.from_contents(fetch_schema(uri, refresh=refresh))
    return Registry(retrieve=retrieve)


def iter_json_files(root):
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if p.suffix.lower() in (".json", ".pbir", ".pbism", ".pbip", ".bim") \
                or p.name == ".platform":
            yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default="powerbi")
    ap.add_argument("--refresh", action="store_true",
                    help="re-download cached schemas")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.exists():
        sys.exit(f"No such directory: {root}")

    registry = make_registry(refresh=args.refresh)
    checked = skipped = 0
    problems = []

    for path in iter_json_files(root):
        rel = path.relative_to(root)
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            problems.append((rel, f"invalid JSON: {e}"))
            continue

        uri = doc.get("$schema") if isinstance(doc, dict) else None
        if not uri:
            # model.bim (TMSL) has no $schema; it is validated by Power BI itself.
            skipped += 1
            continue

        try:
            schema = fetch_schema(uri, refresh=args.refresh)
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            problems.append((rel, f"could not fetch {uri}: {e}"))
            continue

        validator = Draft202012Validator(schema, registry=registry)
        errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
        checked += 1
        for err in errors:
            where = "/".join(str(x) for x in err.absolute_path) or "(root)"
            problems.append((rel, f"{where}: {err.message}"))

    print(f"validated {checked} file(s) against published schemas, "
          f"{skipped} without a $schema (e.g. model.bim)")

    if problems:
        print(f"\n{len(problems)} problem(s):")
        for rel, msg in problems:
            # Schema messages can be enormous when they enumerate a big anyOf.
            if len(msg) > 300:
                msg = msg[:300] + " ...[truncated]"
            print(f"  {rel}\n      {msg}")
        return 1

    print("no schema violations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
