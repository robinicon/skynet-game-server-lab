"""在 V 系列各篇的『代码与运行』节插入一行配套代码指引。

幂等：已存在 `配套开源代码` 的篇目跳过。每处替换做命中校验，不静默失败。
"""

from __future__ import annotations

import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

BLOG = r"C:/workspaces/bookskynet/docs/blog"

# 篇目前缀 → (目录说明, 断言数, run_tests 的 key)
MAP = {
    "V03": ("`unity_client/v03_frame/`（信封黄金实现 + Lua 参考）", 32, "v03"),
    "V04": ("`unity_client/protocol/` + `unity_client/tools/`（注册表与校验器）", 1, "v04"),
    "V05": ("`unity_client/v05_contract/`（覆盖度矩阵）", 26, "v05"),
    "V06": ("`unity_client/v06_errcode/`（错误码 lint）", 23, "v06"),
    "V07": ("`unity_client/v07_role_schema/`（表结构与迁移）", 23, "v07"),
    "V08": ("`unity_client/v08_props/`（泳道编解码 + 槽位冲突）", 29, "v08"),
    "V09": ("`unity_client/v09_reconnect/`（退避与状态机）", 26, "v09"),
    "V10": ("`unity_client/v10_jump/`（窗口期缓存重放）", 31, "v10"),
    "V12": ("`unity_client/v12_art_pipeline/`（manifest 与图片质检）", 24, "v12"),
    "V13": ("`unity_client/v13_build/`（Android 部分）", 39, "v13"),
    "V14": ("`unity_client/v13_build/`（iOS 部分）", 39, "v13"),
    "V15": ("`unity_client/v13_build/`（小游戏部分）", 39, "v13"),
    "V16": ("`unity_client/v16_gate/`（四关门禁）", 22, "v16"),
}

HINT = "> **配套开源代码**：{where}｜{n} 条断言（该目录合计）｜`python unity_client/run_tests.py {key}`\n"


def main() -> int:
    changed = skipped = 0
    for key, (where, n, tkey) in MAP.items():
        files = [f for f in os.listdir(BLOG) if f.startswith(key + "-")]
        if len(files) != 1:
            print(f"[SKIP] {key}: 找到 {len(files)} 个文件")
            skipped += 1
            continue
        path = os.path.join(BLOG, files[0])
        with open(path, encoding="utf-8") as f:
            text = f.read()

        if "配套开源代码" in text:
            print(f"[SKIP] {files[0]}: 已有指引")
            skipped += 1
            continue

        m = re.search(r"^(## [^\n]*代码与运行[^\n]*\n\n)", text, re.M)
        if not m:
            print(f"[FAIL] {files[0]}: 找不到『代码与运行』标题")
            return 1

        line = HINT.format(where=where, n=n, key=tkey)
        text = text[:m.end()] + line + "\n" + text[m.end():]
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"[OK]   {files[0]}")
        changed += 1

    print(f"\n插入 {changed} 处，跳过 {skipped} 处")
    return 0


if __name__ == "__main__":
    sys.exit(main())
