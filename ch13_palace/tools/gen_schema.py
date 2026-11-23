#!/usr/bin/env python3
"""Generate Lua schema tables from conf/schema.xlsx (Excel source of truth).

Usage (from ch13_palace):
    python3 tools/gen_schema.py

Deterministic: same Excel content always produces byte-identical output.
conf/schema.json is emitted as a readable mirror, never as a source.
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import xlsx

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "conf" / "schema.xlsx"
OUT_DIR = ROOT / "generated"
MIRROR = ROOT / "conf" / "schema.json"

VALID_TYPES = {"int", "number", "string", "bool", "map", "array"}
VALID_PERSIST = {"index", "blob", "lazy", "derived", "transient"}
VALID_REPLICATE = {"snapshot", "delta", "on_demand", "none"}
VALID_HANDLERS = {"login", "hero", "item", "mission", "view", "wire", "dev", "cross",
                  "stage", "fight", "shop", "reward", "rank", "gacha", "home", "errand"}


def load():
    if not SOURCE.exists():
        raise FileNotFoundError("source workbook missing: %s (run make_xlsx.py --force first)" % SOURCE)
    book = xlsx.read_book(SOURCE)
    fields = xlsx.rows_to_dicts(book.get("fields", []))
    actions = xlsx.rows_to_dicts(book.get("actions", []))
    errors = xlsx.rows_to_dicts(book.get("errors", []))
    meta = xlsx.rows_to_dicts(book.get("meta", []))

    version = 1
    note = ""
    for row in meta:
        if row.get("key") == "version":
            version = int(row.get("value", "1"))
        elif row.get("key") == "note":
            note = row.get("value", "")

    doc = {
        "version": version,
        "note": note,
        "fields": [],
        "actions": [],
        "errors": {},
    }
    for row in fields:
        doc["fields"].append({
            "fid": int(row["fid"]),
            "name": row["name"],
            "type": row["type"],
            "partition": row["partition"],
            "persist": row["persist"],
            "replicate": row["replicate"],
            "note": row.get("note", ""),
        })
    for row in actions:
        params = [p.strip() for p in row.get("params", "").split(",") if p.strip()]
        doc["actions"].append({
            "aid": int(row["aid"]),
            "op": row["op"],
            "params": params,
            "handler": row["handler"],
            "note": row.get("note", ""),
        })
    for row in errors:
        if row.get("name"):
            doc["errors"][row["name"]] = int(row["value"])
    return doc


def validate(doc):
    errors_list = []
    fields = doc["fields"]
    actions = doc["actions"]

    fids = [f["fid"] for f in fields]
    names = [f["name"] for f in fields]
    aids = [a["aid"] for a in actions]
    ops = [a["op"] for a in actions]

    if len(fids) != len(set(fids)):
        errors_list.append("duplicate field fid")
    if len(names) != len(set(names)):
        errors_list.append("duplicate field name")
    if len(aids) != len(set(aids)):
        errors_list.append("duplicate action aid")
    if len(ops) != len(set(ops)):
        errors_list.append("duplicate action op")

    for f in fields:
        for key, allowed in (("type", VALID_TYPES), ("persist", VALID_PERSIST),
                             ("replicate", VALID_REPLICATE)):
            if f.get(key) not in allowed:
                errors_list.append("field %s: bad %s" % (f.get("name"), key))
    for a in actions:
        if a.get("handler") not in VALID_HANDLERS:
            errors_list.append("action %s: bad handler" % a.get("op"))
        if not isinstance(a.get("params"), list):
            errors_list.append("action %s: params must be list" % a.get("op"))

    if errors_list:
        raise ValueError("; ".join(errors_list))
    return fields, actions


def lua_str(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def gen_fields(fields, version):
    out = ["-- GENERATED FILE - do not edit. Source: conf/schema.xlsx",
           "local M = {}", "M.version = %d" % version, "M.by_id = {"]
    for f in fields:
        out.append(
            "    [%d] = { fid=%d, name=%s, type=%s, partition=%s, persist=%s, replicate=%s },"
            % (f["fid"], f["fid"], lua_str(f["name"]), lua_str(f["type"]),
               lua_str(f["partition"]), lua_str(f["persist"]), lua_str(f["replicate"])))
    out.append("}")
    out.append("M.by_name = {")
    for f in fields:
        out.append("    %s = %d," % (f["name"], f["fid"]))
    out.append("}")
    out.append("M.partitions = {")
    partitions = {}
    for f in fields:
        partitions.setdefault(f["partition"], []).append(f["fid"])
    for name in sorted(partitions):
        out.append("    %s = { %s }," % (name, ", ".join(str(x) for x in partitions[name])))
    out.append("}")
    out.append("M.index_fields = {")
    for f in fields:
        if f["persist"] == "index":
            out.append("    %d," % f["fid"])
    out.append("}")
    out.append("return M")
    return "\n".join(out) + "\n"


def gen_actions(actions):
    out = ["-- GENERATED FILE - do not edit. Source: conf/schema.xlsx",
           "local M = {}", "M.by_aid = {"]
    for a in actions:
        params = ", ".join(lua_str(p) for p in a["params"])
        out.append("    [%d] = { aid=%d, op=%s, params={ %s }, handler=%s },"
                   % (a["aid"], a["aid"], lua_str(a["op"]), params, lua_str(a["handler"])))
    out.append("}")
    out.append("M.by_op = {")
    for a in actions:
        out.append("    [%s] = %d," % (lua_str(a["op"]), a["aid"]))
    out.append("}")
    out.append("return M")
    return "\n".join(out) + "\n"


def gen_errors(errors):
    out = ["-- GENERATED FILE - do not edit. Source: conf/schema.xlsx", "local M = {"]
    for name in sorted(errors):
        out.append("    %s = %d," % (name, errors[name]))
    out.append("}")
    out.append("return M")
    return "\n".join(out) + "\n"


def mirror_json(doc):
    clean = {
        "version": doc["version"],
        "note": doc["note"],
        "fields": [{k: v for k, v in f.items() if k != "note"} for f in doc["fields"]],
        "actions": [{k: v for k, v in a.items() if k != "note"} for a in doc["actions"]],
        "errors": doc["errors"],
    }
    return json.dumps(clean, ensure_ascii=False, indent=2) + "\n"


def main():
    doc = load()
    fields, actions = validate(doc)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    outputs = {
        "fields_generated.lua": gen_fields(fields, doc["version"]),
        "actions_generated.lua": gen_actions(actions),
        "errors_generated.lua": gen_errors(doc["errors"]),
    }
    for name, content in outputs.items():
        (OUT_DIR / name).write_text(content, encoding="utf-8", newline="\n")
        print("generated:", (OUT_DIR / name).relative_to(ROOT))
    MIRROR.write_text(mirror_json(doc), encoding="utf-8", newline="\n")
    print("mirror:  ", MIRROR.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("gen_schema.py FAILED:", exc, file=sys.stderr)
        sys.exit(1)
