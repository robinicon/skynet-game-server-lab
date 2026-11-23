"""AI 出图 manifest 校验 —— V12 配套。

美术资源不开源，但"怎么管这些资源"可以开源：manifest 是 AI 生图与入库之间的
唯一凭据，字段缺一个就复现不出来。本工具只校验凭据，不碰任何图片内容。

用法：
    python unity_client/v12_art_pipeline/manifest_lint.py sample_manifest.json
"""

from __future__ import annotations

import json
import re
import sys

REQUIRED = {
    "file": "输出文件名",
    "workflow": "工作流标识",
    "checkpoint": "底座模型文件名 + 版本",
    "prompt": "正向提示词",
    "negative": "负向提示词",
    "seed": "随机种子（复现的关键）",
    "steps": "采样步数",
    "cfg": "CFG scale",
    "sampler": "采样器",
    "size": "输出分辨率 WxH",
    "generated_at": "生成时间（含时区）",
}

# 命名规范：前缀决定用途与 alpha 要求
NAME_RULES = {
    "icon_": {"alpha": True, "max_side": 1024, "why": "UI 图标，透明底"},
    "ui_": {"alpha": True, "max_side": 1024, "why": "界面图集元素"},
    "tex_": {"alpha": False, "max_side": 2048, "why": "场景贴图，不带 alpha"},
    "char_": {"alpha": True, "max_side": 2048, "why": "角色立绘"},
    "vfx_": {"alpha": True, "max_side": 1024, "why": "特效贴图"},
}

_R_NAME = re.compile(r"^(icon|ui|tex|char|vfx)_[a-z0-9][a-z0-9_]*$")
_R_SIZE = re.compile(r"^(\d{2,5})x(\d{2,5})$")
_R_TZ = re.compile(r"(Z|[+-]\d{2}:\d{2})$")


def is_power_of_two(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0


def parse_size(v) -> tuple[int, int] | None:
    if not isinstance(v, str):
        return None
    m = _R_SIZE.match(v.strip())
    return (int(m.group(1)), int(m.group(2))) if m else None


def lint_manifest(m: dict) -> list[str]:
    """返回问题列表。空 = 可入库。"""
    p: list[str] = []

    for k, why in REQUIRED.items():
        if k not in m or m[k] in (None, "", [], {}):
            p.append(f"缺字段 `{k}`（{why}）")

    f = m.get("file")
    if isinstance(f, str) and f:
        stem = f.rsplit(".", 1)[0]
        if not _R_NAME.match(stem):
            p.append(f"文件名 `{f}` 不符合前缀规范（icon_/ui_/tex_/char_/vfx_ + 小写下划线）")
        ext = f.rsplit(".", 1)[-1].lower() if "." in f else ""
        if ext not in ("png", "jpg", "jpeg", "tga", "webp"):
            p.append(f"扩展名 `{ext or '无'}` 不是常见位图格式")

    seed = m.get("seed")
    if isinstance(seed, str) and not seed.lstrip("-").isdigit():
        p.append(f"`seed` 必须是整数（当前 `{seed}`）——写 random 等于放弃复现")
    elif isinstance(seed, bool) or not isinstance(seed, (int, str)):
        p.append("`seed` 必须是整数")

    size = parse_size(m.get("size"))
    if m.get("size") is not None and size is None:
        p.append(f"`size` 格式应为 WxH（当前 `{m.get('size')}`）")
    if size:
        w, h = size
        if not (is_power_of_two(w) and is_power_of_two(h)):
            p.append(f"`size` {w}x{h} 不是 2 的幂 —— mipmap 与压缩会出问题")
        if w != h and isinstance(f, str):
            p.append(f"`size` {w}x{h} 非正方形，请确认是刻意裁切")

    at = m.get("generated_at")
    if isinstance(at, str) and at and not _R_TZ.search(at.strip()):
        p.append(f"`generated_at` 缺时区（当前 `{at}`）—— 跨时区协作会算错版本")

    for k in ("steps", "cfg"):
        v = m.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            p.append(f"`{k}` 必须是数字")

    return p


def alpha_requirement(filename: str) -> dict | None:
    """按文件名前缀给出该资源的 alpha / 尺寸要求。"""
    stem = filename.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    for prefix, rule in NAME_RULES.items():
        if stem.startswith(prefix):
            return rule
    return None


def lint_files(items: list[dict]) -> list[str]:
    """批量校验一组 manifest；重复文件名也算问题（会互相覆盖）。"""
    out: list[str] = []
    seen: dict[str, int] = {}
    for i, m in enumerate(items):
        for p in lint_manifest(m):
            out.append(f"[#{i} {m.get('file', '?')}] {p}")
        f = m.get("file")
        if isinstance(f, str):
            seen[f] = seen.get(f, 0) + 1
    for f, n in seen.items():
        if n > 1:
            out.append(f"`{f}` 在 manifest 里出现 {n} 次，入库会互相覆盖")
    return out


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        print("用法: manifest_lint.py <manifest.json>")
        return 2
    with open(argv[0], encoding="utf-8") as f:
        data = json.load(f)
    items = data if isinstance(data, list) else data.get("items", [data])
    problems = lint_files(items)
    print(f"校验 {len(items)} 条 manifest")
    if problems:
        print(f"{len(problems)} 个问题：")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
