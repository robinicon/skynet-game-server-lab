#!/usr/bin/env python3
"""Migrate conf/schema.json -> conf/schema.xlsx (Excel source of truth).

Usage:
    python3 tools/make_xlsx.py            # write conf/schema.xlsx from schema.json
    python3 tools/make_xlsx.py --force    # overwrite existing xlsx
    python3 tools/make_xlsx.py --stdout   # print sheet preview, do not write

This is a one-off bootstrap tool. After migration, edit the Excel file
directly (Excel / WPS / LibreOffice) and run `make gen` to regenerate Lua.
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xlsx

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "conf" / "schema.json"
TARGET = ROOT / "conf" / "schema.xlsx"

FIELD_COLS = ["fid", "name", "type", "partition", "persist", "replicate", "note"]
ACTION_COLS = ["aid", "op", "params", "handler", "note"]
ERROR_COLS = ["name", "value", "note"]


def build_sheets(doc):
    fields = [FIELD_COLS]
    for f in doc["fields"]:
        fields.append([
            str(f["fid"]), f["name"], f["type"], f["partition"],
            f["persist"], f["replicate"], f.get("note", ""),
        ])

    actions = [ACTION_COLS]
    for a in doc["actions"]:
        actions.append([
            str(a["aid"]), a["op"], ",".join(a["params"]), a["handler"], a.get("note", ""),
        ])

    errors = [ERROR_COLS]
    for name, value in doc.get("errors", {}).items():
        errors.append([name, str(value), ""])

    meta = [["key", "value", "note"],
            ["version", str(doc.get("version", 1)), "schema version, bump on compatible extension"],
            ["note", doc.get("note", ""), "free text"]]

    return {"fields": fields, "actions": actions, "errors": errors, "meta": meta}


def main():
    args = set(sys.argv[1:])
    if not SOURCE.exists():
        print("source missing:", SOURCE, file=sys.stderr)
        return 1
    if TARGET.exists() and "--force" not in args and "--stdout" not in args:
        print("target exists (use --force):", TARGET, file=sys.stderr)
        return 1

    with SOURCE.open(encoding="utf-8") as f:
        doc = json.load(f)

    sheets = build_sheets(doc)
    if "--stdout" in args:
        for name, rows in sheets.items():
            print("---", name)
            for row in rows:
                print(" | ".join(str(v) for v in row))
        return 0

    xlsx.write_book(TARGET, sheets)
    check = xlsx.read_book(TARGET)
    for name in sheets:
        if name not in check:
            print("write failed: sheet missing after read:", name, file=sys.stderr)
            return 1
    print("created:", TARGET.relative_to(ROOT))
    print("sheets:", ", ".join(sheets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
