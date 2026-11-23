"""客户端开源集统一自测入口 —— 一条命令跑完所有篇目的检查。

用法：
    python unity_client/run_tests.py            # 跑全部
    python unity_client/run_tests.py v03 v06    # 只跑指定篇目
    python unity_client/run_tests.py --list     # 列出可跑的模块

规则与 skynet 各章一致：每个模块独立可跑，这里只做聚合与汇总。
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

# 模块 → (测试脚本, 一句话职责)。顺序按篇目。
MODULES: list[tuple[str, str, str]] = [
    ("v03", "v03_frame/test_frame.py", "信封层编解码 + 双栈判别"),
    ("v04", "tools/checkers/check_opcode.py", "opcode 只增不改校验"),
    ("v05", "v05_contract/test_coverage.py", "契约覆盖度矩阵"),
    ("v06", "v06_errcode/test_errcode.py", "错误码一致性 lint"),
    ("v07", "v07_role_schema/test_schema.py", "roles 表结构检查"),
    ("v08", "v08_props/test_props.py", "泳道编解码 + 槽位冲突"),
    ("v09", "v09_reconnect/test_reconnect.py", "退避与重连状态机"),
    ("v10", "v10_jump/test_jump.py", "跳转窗口期缓存重放"),
    ("v12", "v12_art_pipeline/test_pipeline.py", "美术 manifest 与图片质检"),
    ("v13", "v13_build/test_build.py", "Android / iOS / 小游戏出包检查"),
    ("v16", "v16_gate/test_gate.py", "联调验收门禁"),
]

_R_TOTAL = re.compile(r"(\d+) PASS, (\d+) FAIL, (\d+) TOTAL")


def run_one(key: str, rel: str) -> tuple[int, int, int, str]:
    path = os.path.join(ROOT, rel)
    if not os.path.isfile(path):
        return (0, 1, 1, f"脚本不存在：{rel}")
    r = subprocess.run([sys.executable, path], capture_output=True, text=True,
                       cwd=ROOT, timeout=300)
    m = _R_TOTAL.search(r.stdout or "")
    if m:
        ok, bad, total = (int(x) for x in m.groups())
    else:
        # 非 selftest 风格的脚本（如 check_opcode.py）只给退出码，按 1 条断言计
        ok, bad, total = (1, 0, 1) if r.returncode == 0 else (0, 1, 1)
    tail = "" if r.returncode == 0 else (r.stdout or r.stderr)[-400:]
    return (ok, bad, total, tail)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv

    if "--list" in argv:
        for key, rel, why in MODULES:
            print(f"  {key:<4} {rel:<38} {why}")
        return 0

    picked = [m for m in MODULES if not argv or m[0] in argv]
    if not picked:
        print(f"没有匹配的模块：{' '.join(argv)}")
        return 2

    total_ok = total_bad = total_n = 0
    failures: list[tuple[str, str]] = []
    print(f"运行 {len(picked)} 个模块\n")
    for key, rel, why in picked:
        ok, bad, n, tail = run_one(key, rel)
        total_ok += ok
        total_bad += bad
        total_n += n
        mark = "OK  " if bad == 0 else "FAIL"
        print(f"  [{mark}] {key:<4} {n:>3} 断言  {why}")
        if tail:
            failures.append((key, tail))

    print(f"\n合计：{total_ok} PASS, {total_bad} FAIL, {total_n} TOTAL")
    if failures:
        print("\n失败详情：")
        for key, tail in failures:
            print(f"\n--- {key} ---")
            print(tail)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
