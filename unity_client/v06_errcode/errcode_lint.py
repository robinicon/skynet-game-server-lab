"""错误码一致性 lint —— V06 配套。

问题（台账 C-27）：服务端 `shared/error_code.lua` 与契约 `Msg_Common.proto` 各有一套错误码，
1~6 六个数值相同、含义完全不同。编译能过、单测能过、联调时提示语系统性错配。

本工具做三件事：
  1. 抓出"同值不同名"（撞车）与"同名不同值"（漂移）
  2. 校验人工维护的语义映射表 `SEMANTIC_MAP` 两端是否都还存在（防映射过期）
  3. `--strict` 有撞车即 rc=1，可进 CI

用法：
    python unity_client/v06_errcode/errcode_lint.py
    python unity_client/v06_errcode/errcode_lint.py --strict
"""

from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SERVER_ERRCODE = os.path.join(ROOT, "ch4_login", "shared", "error_code.lua")
CLIENT_PROTO = os.path.join(ROOT, "unity_client", "protocol", "protos", "Msg_Common.proto")

# 语义映射：服务端码 → 契约码。这是"人工裁决"的交付物，lint 只负责校验它没过期。
# 只映射真正同义的；含义不同的（如 ERR_ALREADY_LOGGED_IN 无对应）留在 UNMAPPED。
SEMANTIC_MAP = {
    "ERR_TOKEN_EXPIRED": "ERR_TICKET_EXPIRED",
    "ERR_INVALID_TOKEN": "ERR_TICKET_INVALID",
}

_RE_LUA = re.compile(r"^M\.([A-Z][A-Z0-9_]*)\s*=\s*(-?\d+)\s*$")
_RE_PROTO = re.compile(r"^\s*(ERR_[A-Z0-9_]+)\s*=\s*(-?\d+)\s*;")


def parse_lua(path: str = SERVER_ERRCODE) -> dict[str, int]:
    """从 error_code.lua 抽 M.NAME = N。"""
    out: dict[str, int] = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = _RE_LUA.match(line.strip())
            if m:
                out[m.group(1)] = int(m.group(2))
    return out


def parse_proto(path: str = CLIENT_PROTO) -> dict[str, int]:
    """从 Msg_Common.proto 的 enum ErrCode 抽 NAME = N。

    只取 ErrCode 这一段，避免把其它 enum 混进来。
    """
    out: dict[str, int] = {}
    in_enum = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s.startswith("enum "):
                in_enum = "ErrCode" in s
                continue
            if in_enum and s.startswith("}"):
                in_enum = False
                continue
            if in_enum:
                m = _RE_PROTO.match(line)
                if m:
                    out[m.group(1)] = int(m.group(2))
    return out


def normalize(name: str) -> str:
    """去掉命名风格差异，用于判断"同义不同名"。

    OK 与 ERR_OK 本质同义，不算撞车；ERR_TOKEN_EXPIRED 与 ERR_TICKET_EXPIRED
    去掉前缀后仍然不同（token ≠ ticket），必须算。
    """
    s = name.upper()
    for p in ("ERR_", "ERROR_"):
        if s.startswith(p):
            s = s[len(p):]
            break
    return s.replace("_", "")


def find_collisions(server: dict[str, int], client: dict[str, int]) -> list[tuple[int, list[str], list[str]]]:
    """同值不同名（排除命名风格等价的，如 OK / ERR_OK）。返回 [(值, 服务端名, 契约名)]。"""
    by_val_s: dict[int, list[str]] = {}
    by_val_c: dict[int, list[str]] = {}
    for n, v in server.items():
        by_val_s.setdefault(v, []).append(n)
    for n, v in client.items():
        by_val_c.setdefault(v, []).append(n)
    out = []
    for v in sorted(set(by_val_s) & set(by_val_c)):
        sn, cn = sorted(by_val_s[v]), sorted(by_val_c[v])
        if {normalize(x) for x in sn} == {normalize(x) for x in cn}:
            continue                      # 同义不同名，不算撞车
        out.append((v, sn, cn))
    return out


def find_drift(server: dict[str, int], client: dict[str, int]) -> list[tuple[str, int, int]]:
    """同名不同值。"""
    return [(n, server[n], client[n]) for n in sorted(set(server) & set(client))
            if server[n] != client[n]]


def check_map(server: dict[str, int], client: dict[str, int]) -> list[str]:
    """映射表两端必须都存在，否则是"过期映射"，比撞车更危险（静默失效）。"""
    bad = []
    for s, c in SEMANTIC_MAP.items():
        if s not in server:
            bad.append(f"映射左端 {s} 已不存在于 error_code.lua")
        if c not in client:
            bad.append(f"映射右端 {c} 已不存在于 Msg_Common.proto")
    return bad


def report(server: dict[str, int], client: dict[str, int]) -> tuple[int, list[str]]:
    """打印报告，返回 (撞车数, 文本行)。"""
    lines: list[str] = []
    lines.append(f"服务端 error_code.lua: {len(server)} 个")
    lines.append(f"契约 Msg_Common.ErrCode: {len(client)} 个")

    cols = find_collisions(server, client)
    lines.append("")
    if cols:
        lines.append(f"数值撞车 {len(cols)} 处（同值不同名，联调提示语必错）：")
        lines.append(f"  {'值':<5}{'服务端':<26}{'契约'}")
        for v, sn, cn in cols:
            lines.append(f"  {v:<5}{'/'.join(sn):<26}{'/'.join(cn)}")
    else:
        lines.append("数值撞车：0")

    drift = find_drift(server, client)
    lines.append("")
    if drift:
        lines.append(f"同名不同值 {len(drift)} 处：")
        for n, sv, cv in drift:
            lines.append(f"  {n}: 服务端 {sv} vs 契约 {cv}")
    else:
        lines.append("同名不同值：0（当前两侧无同名项）")

    lines.append("")
    lines.append("语义映射（人工裁决，lint 校验其有效性）：")
    for s, c in SEMANTIC_MAP.items():
        sv, cv = server.get(s), client.get(c)
        lines.append(f"  {s}({sv})  →  {c}({cv})")
        if sv is not None and cv is not None and sv == cv:
            lines.append("      注意：两侧数值恰好相同，但这不是前提，仅供参考")

    unmapped = [n for n in sorted(server) if n not in SEMANTIC_MAP
                and n not in ("OK",) and server[n] > 0]
    lines.append("")
    lines.append(f"服务端侧无契约对应（需产品定文案，不要硬塞）: {len(unmapped)} 个")
    lines.append("  " + ", ".join(unmapped))

    bad_map = check_map(server, client)
    if bad_map:
        lines.append("")
        lines.append("映射表过期：")
        for b in bad_map:
            lines.append(f"  ! {b}")

    return len(cols) + len(drift) + len(bad_map), lines


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true", help="有不一致时返回 1")
    args = ap.parse_args(argv)

    server, client = parse_lua(), parse_proto()
    n, lines = report(server, client)
    print("\n".join(lines))
    print()
    if n:
        print(f"结论：发现 {n} 处不一致 —— 必须在联调前收敛，否则错误提示会系统性错配。")
    else:
        print("结论：两侧一致。")
    return 1 if (args.strict and n) else 0


if __name__ == "__main__":
    sys.exit(main())
