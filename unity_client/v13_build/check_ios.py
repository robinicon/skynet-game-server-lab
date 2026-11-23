"""iOS 出包与"不能热更代码"的硬检查 —— V14 配套。

两条线：
  1. 构建配置（IL2CPP / 包名 / 目标系统版本）
  2. 源码里有没有"下发可执行代码"的痕迹 —— 这是 2.5.2 的红线，也是本项目
     定案"不做代码热更"的可执行证明（台账 C-18）

用法：
    python unity_client/v13_build/check_ios.py
    python unity_client/v13_build/check_ios.py --scan /path/to/Assets
"""

from __future__ import annotations

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import project_settings as PS  # noqa: E402

# 下发/加载外部程序集的痕迹。命中即需要人工确认，不是"一律违规"。
HOTFIX_PATTERNS = [
    (re.compile(r"\bHybridCLR\b"), "HybridCLR（热更程序集加载）"),
    (re.compile(r"\bILRuntime\b"), "ILRuntime（DLL 解释执行）"),
    (re.compile(r"\bXLua\b|\bxLua\b"), "xLua（Lua 绑定 + 代码热更）"),
    (re.compile(r"\bToLua\b"), "ToLua"),
    (re.compile(r"Assembly\.Load(From)?"), "Assembly.Load（动态加载程序集）"),
    (re.compile(r"\bLoadFromFile\b.*\.(dll|bytes)"), "从文件加载 dll/bytes"),
]

SKIP_DIRS = {".git", "Library", "Temp", "obj", "Build", "Builds", "Logs"}


def check_config(settings: dict) -> list[str]:
    p: list[str] = []
    backend = PS.sub(settings, "scriptingBackend", "iPhone")
    if backend is None:
        p.append("scriptingBackend 未为 iPhone 显式设置 —— iOS 只支持 IL2CPP，"
                 "缺失通常意味着工程没真正出过 iOS 包")
    elif backend != 1:
        p.append(f"scriptingBackend.iPhone={backend}（{PS.scripting_backend_name(backend)}）"
                 f"—— iOS 必须 IL2CPP(1)")

    appid = PS.sub(settings, "applicationIdentifier", "iPhone")
    if not appid:
        p.append("applicationIdentifier(iPhone) 未设置 —— 无法生成 Provisioning Profile")

    target = settings.get("iOSTargetOSVersionString")
    if not target:
        p.append("iOSTargetOSVersionString 未设置 —— 建议显式固定最低系统版本")
    return p


def scan_hotfix(root: str) -> list[tuple[str, int, str, str]]:
    """扫 .cs 里的热更痕迹。返回 [(相对路径, 行号, 规则名, 行内容)]。"""
    hits: list[tuple[str, int, str, str]] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".cs"):
                continue
            full = os.path.join(dirpath, fn)
            try:
                with open(full, encoding="utf-8", errors="replace") as f:
                    for i, line in enumerate(f, 1):
                        for pat, why in HOTFIX_PATTERNS:
                            if pat.search(line):
                                rel = os.path.relpath(full, root)
                                hits.append((rel, i, why, line.strip()[:90]))
            except OSError:
                continue
    return hits


def summary(settings: dict) -> str:
    backend = PS.sub(settings, "scriptingBackend", "iPhone")
    appid = PS.sub(settings, "applicationIdentifier", "iPhone")
    target = settings.get("iOSTargetOSVersionString")
    return (f"backend={PS.scripting_backend_name(backend)}  "
            f"appId={appid or '未设置'}  target={target or '未设置'}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=PS.DEFAULT_PATH)
    ap.add_argument("--scan", help="扫描该目录下的 .cs，检查热更痕迹")
    args = ap.parse_args(argv)

    rc = 0
    if os.path.isfile(args.file):
        s = PS.load(args.file)
        print(summary(s))
        problems = check_config(s)
        print()
        if problems:
            print(f"iOS 配置检查：{len(problems)} 项不通过")
            for x in problems:
                print(f"  ✗ {x}")
            rc = 1
        else:
            print("iOS 配置检查：通过")
    else:
        print(f"跳过配置检查（找不到 {args.file}）")
        rc = 2

    if args.scan:
        print()
        if not os.path.isdir(args.scan):
            print(f"跳过源码扫描（{args.scan} 不是目录）")
            return rc
        hits = scan_hotfix(args.scan)
        if hits:
            print(f"热更痕迹：{len(hits)} 处（需人工确认是否属于下发可执行代码）")
            for rel, ln, why, text in hits[:20]:
                print(f"  {rel}:{ln}  {why}")
                print(f"      {text}")
            rc = 1
        else:
            print("热更痕迹：0 —— 与『只做资源热更』的定案一致")
    return rc


if __name__ == "__main__":
    sys.exit(main())
