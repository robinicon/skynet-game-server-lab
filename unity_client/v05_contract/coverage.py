"""契约覆盖度矩阵 —— V05 配套。

做一件事：把"界面需要什么数据"与"契约里有什么消息"对撞，输出缺口表。
不靠人肉读 YAML，避免需求加了界面却忘了加协议（C-04 就是这么产生的）。

用法：
    python unity_client/v05_contract/coverage.py            # 打印矩阵
    python unity_client/v05_contract/coverage.py --strict   # 有缺口时 rc=1（可进 CI）
    python unity_client/v05_contract/coverage.py --propose  # 给出可直接贴进 registry 的行
"""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 PyYAML：pip install pyyaml\n")
    raise

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "protocol", "opcode_registry.yaml")
SCREENS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui_screens.json")


def load_registry(path: str = REGISTRY) -> dict:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def load_screens(path: str = SCREENS) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def as_int(v) -> int:
    """registry 里的 id 可能是 int（YAML 解析 `0x0001` 会变成 1），也可能是字符串。

    坑：int("13", 16) == 19 —— 把已解析的十进制当十六进制重解析会静默错位。
    """
    if isinstance(v, int):
        return v
    s = str(v).strip()
    return int(s, 16) if s.lower().startswith("0x") else int(s, 0)


def registry_names(reg: dict) -> dict[str, dict]:
    return {op["name"]: op for op in reg.get("opcodes", [])}


def channel_usage(reg: dict) -> dict[str, list[int]]:
    """按通道统计已占用的 id（升序），用于算"下一个可用 id"。"""
    used: dict[str, list[int]] = {}
    for op in reg.get("opcodes", []):
        used.setdefault(op["channel"], []).append(as_int(op["id"]))
    for k in used:
        used[k].sort()
    return used


def next_free_id(used_ids: list[int], limit: int = 0xFFFF) -> int | None:
    """从 0x0001 起找第一个空位。注意 0x0000 保留。"""
    taken = set(used_ids)
    for i in range(1, limit + 1):
        if i not in taken:
            return i
    return None


def build_matrix(reg: dict, screens: dict) -> list[dict]:
    names = registry_names(reg)
    rows = []
    for s in screens["screens"]:
        missing = [n for n in s["needs"] if n not in names]
        rows.append({
            "prefab": s["prefab"],
            "flow": s["flow"],
            "needs": s["needs"],
            "missing": missing,
            "passive": s.get("passive", False),
            "note": s.get("note", ""),
        })
    return rows


def fmt_matrix(rows: list[dict], names: dict[str, dict]) -> str:
    out = []
    head = f"{'界面':<22}{'流程':<8}{'状态':<8}所需 / 缺口"
    out.append(head)
    out.append("-" * 92)
    for r in rows:
        if not r["needs"]:
            state, detail = "—", "无协议"
        elif r["missing"]:
            state = "缺 " + str(len(r["missing"]))
            detail = " ".join(
                (f"[OK]{n}" if n not in r["missing"] else f"[缺]{n}") for n in r["needs"]
            )
        else:
            state = "OK"
            detail = " ".join(r["needs"])
        out.append(f"{r['prefab']:<22}{r['flow']:<8}{state:<8}{detail}")
    return "\n".join(out)


def fmt_opcode_table(rows: list[dict], names: dict[str, dict]) -> str:
    """已覆盖 opcode 的名称/通道/id/消息，按界面顺序去重。"""
    out = ["", "已覆盖的 opcode（名称 / 通道 / id / 消息）："]
    seen = set()
    for r in rows:
        for n in r["needs"]:
            if n in names and n not in seen:
                seen.add(n)
                op = names[n]
                out.append(
                    f"  {n:<24} {op['channel']:<6} 0x{as_int(op['id']):04X}  {op.get('proto', '')}"
                )
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true", help="有缺口时返回 1")
    ap.add_argument("--propose", action="store_true", help="输出可直接贴进 registry 的行")
    args = ap.parse_args(argv)

    reg = load_registry()
    screens = load_screens()
    names = registry_names(reg)
    rows = build_matrix(reg, screens)

    print(f"registry v{reg.get('version')}，共 {len(reg.get('opcodes', []))} 条 opcode")
    print()
    print(fmt_matrix(rows, names))

    used = channel_usage(reg)
    print()
    for ch in sorted(used):
        ids = used[ch]
        nxt = next_free_id(ids)
        span = f"0x{ids[0]:04X}~0x{ids[-1]:04X}" if ids else "-"
        print(f"  通道 {ch:<6} 占用 {len(ids):>2} 个  区间 {span:<15} 下一个可用 0x{nxt:04X}")

    gaps = [r for r in rows if r["missing"]]
    print()
    if gaps:
        print(f"缺口：{len(gaps)} 个界面无完整契约")
        for r in gaps:
            print(f"  - {r['prefab']}: 缺 {', '.join(r['missing'])}")
    else:
        print("缺口：0")

    if args.propose:
        print("\n提案（只增不改，追加到 opcodes 末尾）：")
        for p in screens["proposals"]:
            used_ids = used.get(p["channel"], [])
            pid = as_int(p["id"])
            mark = "空闲" if pid not in used_ids else "!!! 已占用"
            print(f"  - {{name: {p['name']}, channel: {p['channel']}, id: {p['id']}, "
                  f"proto: {p['proto']}}}" + (f"   # {mark}" if mark != "空闲" else ""))
            if mark != "空闲":
                return 1

    return 1 if (args.strict and gaps) else 0


if __name__ == "__main__":
    sys.exit(main())
