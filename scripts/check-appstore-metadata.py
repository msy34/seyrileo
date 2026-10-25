#!/usr/bin/env python3
"""Checks docs/appstore/metadata.json against App Store Connect length limits."""
import json, pathlib, sys

LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "keywords": 100, "description": 4000, "release_notes": 4000}
data = json.loads((pathlib.Path(__file__).resolve().parent.parent / "docs/appstore/metadata.json").read_text(encoding="utf-8"))
problems = []
for locale, fields in data.items():
    if locale.startswith("_") or not isinstance(fields, dict) or "name" not in fields:
        continue
    for key, limit in LIMITS.items():
        value = fields.get(key, "")
        if not value:
            problems.append(f"{locale}: {key} missing")
        elif len(value) > limit:
            problems.append(f"{locale}: {key} is {len(value)} > {limit}")
    print(f"{locale}: " + ", ".join(f"{k}={len(fields.get(k, ''))}" for k in LIMITS))
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
