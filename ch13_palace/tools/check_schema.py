#!/usr/bin/env python3
"""Verify generated Lua schema tables are in sync with conf/schema.xlsx.

Usage (from ch13_palace):
    python3 tools/check_schema.py
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gen_schema as gen

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    try:
        doc = gen.load()
        fields, actions = gen.validate(doc)
    except Exception as exc:
        print("CHECK FAIL: schema source invalid:", exc, file=sys.stderr)
        return 1

    expected = {
        "fields_generated.lua": gen.gen_fields(fields, doc["version"]),
        "actions_generated.lua": gen.gen_actions(actions),
        "errors_generated.lua": gen.gen_errors(doc["errors"]),
    }
    failed = []
    for name, content in expected.items():
        path = ROOT / "generated" / name
        if not path.exists():
            failed.append(name + ": missing")
            continue
        if path.read_text(encoding="utf-8") != content:
            failed.append(name + ": out of date, run make gen")
    mirror = ROOT / "conf" / "schema.json"
    if not mirror.exists() or mirror.read_text(encoding="utf-8") != gen.mirror_json(doc):
        failed.append("conf/schema.json mirror out of date, run make gen")

    if failed:
        for item in failed:
            print("CHECK FAIL:", item, file=sys.stderr)
        return 1
    print("schema check: %d fields, %d actions, %d errors, xlsx in sync with 3 generated files + mirror"
          % (len(fields), len(actions), len(doc["errors"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
