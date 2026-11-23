"""微信小游戏首包预算与传输约束 —— V15 配套。

两条硬约束：
  1. 首包体积 —— 主包与总包都有上限（限额以官方当年公告为准，代码里是常量，可改）
  2. 传输 —— 小游戏只能 WSS，TCP 直连不做

体积数字必须来自构建产物清单（`first_package.json`），脚本不内置任何"估算值"，
避免把拍脑袋的数字写成结论。

用法：
    python unity_client/v13_build/check_minigame.py --manifest first_package.json
    python unity_client/v13_build/check_minigame.py --endpoint wss://game.example.com/ws
"""

from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

MB = 1024 * 1024

# 限额常量。改这里即可，勿散落在文档里。
LIMITS = {
    "main_package_bytes": 4 * MB,      # 首包（主包）
    "total_bytes": 20 * MB,            # 含分包的总量
    "fps": 30,
    "memory_bytes": 350 * MB,
    "drawcall": 150,
    "ui_texture_max": 1024,
    "scene_texture_max": 2048,
}


def load_manifest(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def sum_bytes(items: list[dict]) -> int:
    total = 0
    for it in items:
        b = it.get("bytes")
        if not isinstance(b, int) or b < 0:
            raise ValueError(f"清单项 {it.get('path', '?')} 的 bytes 非法：{b!r}")
        total += b
    return total


def check_budget(manifest: dict, limits: dict | None = None) -> list[str]:
    """返回问题列表。清单字段：main[] / sub[]，每项 {path, bytes}。"""
    lim = limits or LIMITS
    p: list[str] = []
    main_items = manifest.get("main") or []
    sub_items = manifest.get("sub") or []

    if not main_items:
        return ["清单里没有 main[]，无法判定首包 —— 不要用估算值代替构建产物"]

    main_b = sum_bytes(main_items)
    total_b = main_b + sum_bytes(sub_items)

    if main_b > lim["main_package_bytes"]:
        over = main_b - lim["main_package_bytes"]
        p.append(f"首包 {main_b / MB:.2f} MB 超限 {over / MB:.2f} MB"
                 f"（上限 {lim['main_package_bytes'] / MB:.0f} MB）—— 需移入分包")
        for it in sorted(main_items, key=lambda x: -x.get("bytes", 0))[:5]:
            p.append(f"    占用最大：{it.get('path')}  {it.get('bytes', 0) / 1024:.0f} KB")

    if total_b > lim["total_bytes"]:
        p.append(f"总包 {total_b / MB:.2f} MB 超限（上限 {lim['total_bytes'] / MB:.0f} MB）")

    return p


def check_transport(endpoint: str | None) -> list[str]:
    """小游戏只能走 WSS，且不能用 IP 直连（证书校验会失败）。"""
    if not endpoint:
        return ["未提供 endpoint，无法校验传输 —— 小游戏不能假设 TCP 可用"]
    p: list[str] = []
    if not endpoint.startswith("wss://"):
        p.append(f"endpoint `{endpoint}` 不是 wss:// —— 小游戏平台不允许明文 ws/tcp")
    host = endpoint.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
    if host.replace(".", "").isdigit():
        p.append(f"endpoint 用了 IP `{host}` —— 证书按域名签发，IP 直连会握手失败")
    return p


def check_perf(fps: int | None, memory_bytes: int | None, drawcall: int | None,
               limits: dict | None = None) -> list[str]:
    """真机性能阈值校验。三个值都来自实测，不传就报"缺数据"。"""
    lim = limits or LIMITS
    p: list[str] = []
    if fps is None:
        p.append("缺 fps 实测值")
    elif fps < lim["fps"]:
        p.append(f"fps {fps} 低于 {lim['fps']}")
    if memory_bytes is None:
        p.append("缺内存实测值")
    elif memory_bytes > lim["memory_bytes"]:
        p.append(f"内存 {memory_bytes / MB:.0f} MB 超 {lim['memory_bytes'] / MB:.0f} MB")
    if drawcall is None:
        p.append("缺 drawcall 实测值")
    elif drawcall > lim["drawcall"]:
        p.append(f"drawcall {drawcall} 超 {lim['drawcall']}")
    return p


def report(manifest: dict) -> str:
    main_b = sum_bytes(manifest.get("main") or [])
    sub_b = sum_bytes(manifest.get("sub") or [])
    return (f"首包 {main_b / MB:.2f} MB（上限 {LIMITS['main_package_bytes'] / MB:.0f} MB）  "
            f"分包 {sub_b / MB:.2f} MB  "
            f"合计 {(main_b + sub_b) / MB:.2f} MB（上限 {LIMITS['total_bytes'] / MB:.0f} MB）")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(HERE, "first_package.example.json"))
    ap.add_argument("--endpoint")
    ap.add_argument("--fps", type=int)
    ap.add_argument("--memory-mb", type=int)
    ap.add_argument("--drawcall", type=int)
    args = ap.parse_args(argv)

    rc = 0
    problems: list[str] = []

    if os.path.isfile(args.manifest):
        m = load_manifest(args.manifest)
        try:
            print(report(m))
        except ValueError as e:
            print(f"清单非法：{e}")
            return 2
        problems += check_budget(m)
    else:
        print(f"找不到清单 {args.manifest}")
        rc = 2

    problems += check_transport(args.endpoint)
    problems += check_perf(args.fps,
                           args.memory_mb * MB if args.memory_mb is not None else None,
                           args.drawcall)

    print()
    if problems:
        print(f"小游戏检查：{len(problems)} 项不通过")
        for p in problems:
            print(f"  ✗ {p}")
        return 1
    print("小游戏检查：通过")
    return rc


if __name__ == "__main__":
    sys.exit(main())
