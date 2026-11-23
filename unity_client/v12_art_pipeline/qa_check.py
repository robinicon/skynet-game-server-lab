"""入库前图片质检 —— V12 配套。

只读图片头（尺寸/模式），不解码像素，所以能扫几千张。规则来自 manifest 的前缀约定：
icon_/ui_/vfx_ 要 alpha，tex_ 不要 alpha，2 的幂，尺寸上限。

不包含任何美术资源，测试图由 PIL 现场生成。
"""

from __future__ import annotations

import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.stderr.write("需要 Pillow：pip install pillow\n")
    raise

from manifest_lint import NAME_RULES, alpha_requirement, is_power_of_two, parse_size


def check_image(path: str, size_rule: tuple[int, int] | None = None) -> list[str]:
    """检查一张图，返回问题列表。size_rule 可与 manifest 声明比对。"""
    problems: list[str] = []
    name = os.path.basename(path)

    with Image.open(path) as im:
        w, h = im.size
        mode = im.mode
        has_alpha = mode in ("RGBA", "LA") or (mode == "P" and "transparency" in im.info)

    rule = alpha_requirement(name)
    if rule is None:
        problems.append(f"{name}: 无匹配前缀（icon_/ui_/tex_/char_/vfx_），无法判定入库规则")
    else:
        if rule["alpha"] and not has_alpha:
            problems.append(f"{name}: {rule['why']}，需要 alpha（当前 {mode}）")
        if not rule["alpha"] and has_alpha:
            problems.append(f"{name}: {rule['why']}，不应带 alpha（当前 {mode}），白边/额外显存")
        if max(w, h) > rule["max_side"]:
            problems.append(f"{name}: {w}x{h} 超过上限 {rule['max_side']}")

    if not (is_power_of_two(w) and is_power_of_two(h)):
        problems.append(f"{name}: {w}x{h} 不是 2 的幂")

    if size_rule and (w, h) != size_rule:
        problems.append(f"{name}: 实际 {w}x{h} 与 manifest 声明 {size_rule[0]}x{size_rule[1]} 不符")

    if w <= 0 or h <= 0:
        problems.append(f"{name}: 尺寸非法")

    return problems


def check_manifest_pair(item: dict, base_dir: str) -> list[str]:
    """manifest 一条 + 实际文件是否对得上（文件缺失本身也是问题）。"""
    f = item.get("file", "")
    path = os.path.join(base_dir, f)
    if not os.path.isfile(path):
        return [f"{f}: 文件不存在（manifest 与产物脱节）"]
    return check_image(path, parse_size(item.get("size")))


def scan_dir(d: str) -> list[str]:
    """扫目录下所有位图，返回全部问题。"""
    exts = (".png", ".jpg", ".jpeg", ".tga", ".webp")
    problems: list[str] = []
    for root, _, files in os.walk(d):
        for fn in sorted(files):
            if fn.lower().endswith(exts):
                try:
                    problems += check_image(os.path.join(root, fn))
                except Exception as e:  # noqa: BLE001
                    problems.append(f"{fn}: 打开失败 {e}")
    return problems


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        print("用法: qa_check.py <目录或图片>")
        return 2
    target = argv[0]
    problems = scan_dir(target) if os.path.isdir(target) else check_image(target)
    if problems:
        print(f"{len(problems)} 个问题：")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
