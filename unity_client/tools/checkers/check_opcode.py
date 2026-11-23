#!/usr/bin/env python3
"""opcode 只增不改校验器 · CI 强制
比对 protocol/opcode_registry.yaml 与快照 protocol/opcode_snapshot.yaml：
  新增    → 放行（并提示更新快照）
  修改/删除/复用 → 打回（exit 1）
用法: python tools/checkers/check_opcode.py [--update-snapshot]
"""
import argparse
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "protocol" / "opcode_registry.yaml"
SNAPSHOT = ROOT / "protocol" / "opcode_snapshot.yaml"


def to_hex(v):
    return v if isinstance(v, int) else int(str(v), 16)


def fingerprint():
    data = yaml.safe_load(REGISTRY.read_text(encoding="utf-8"))
    channels = {name: to_hex(v) for name, v in data["channels"].items()}
    ops = {}
    for op in data["opcodes"]:
        value = (channels[op["channel"]] << 16) | to_hex(op["id"])
        ops[op["name"]] = {"value": value, "channel": op["channel"], "id": to_hex(op["id"]),
                           "proto": op.get("proto", "")}
    return data["version"], channels, ops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update-snapshot", action="store_true")
    args = ap.parse_args()
    version, channels, ops = fingerprint()

    if args.update_snapshot or not SNAPSHOT.exists():
        SNAPSHOT.write_text(
            yaml.safe_dump({"version": version, "channels": channels, "opcodes": ops},
                           allow_unicode=True, sort_keys=True),
            encoding="utf-8")
        print(f"[OK] 快照已更新: {len(ops)} opcodes (registry v{version})")
        return

    snap = yaml.safe_load(SNAPSHOT.read_text(encoding="utf-8"))
    snap_ops = snap.get("opcodes", {})
    added = set(ops) - set(snap_ops)
    removed = set(snap_ops) - set(ops)
    changed = {n for n in set(ops) & set(snap_ops) if ops[n] != snap_ops[n]}
    snap_channels = snap.get("channels", {})
    ch_changed = {k for k in set(channels) & set(snap_channels) if channels[k] != snap_channels[k]}
    ch_removed = set(snap_channels) - set(channels)

    if removed or changed or ch_changed or ch_removed:
        print("[FAIL] 违反『只增不改』纪律：")
        for n in sorted(removed):
            print(f"  删除: {n}")
        for n in sorted(changed):
            print(f"  修改: {n} {snap_ops[n]} -> {ops[n]}")
        for n in sorted(ch_removed | ch_changed):
            print(f"  通道变更: {n}")
        sys.exit(1)

    if added:
        print(f"[OK] 合规新增 {len(added)} 个 opcode: {', '.join(sorted(added))}")
    else:
        print("[OK] 无变更")
    if added:
        SNAPSHOT.write_text(
            yaml.safe_dump({"version": version, "channels": channels, "opcodes": ops},
                           allow_unicode=True, sort_keys=True),
            encoding="utf-8")
        print(f"[OK] 快照已更新至 {len(ops)} opcodes")


if __name__ == "__main__":
    main()
