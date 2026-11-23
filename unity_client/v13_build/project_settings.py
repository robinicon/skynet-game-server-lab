"""ProjectSettings.asset 极简解析 —— V13/V14 共用底座。

Unity 的 ProjectSettings.asset 是 Unity-YAML：字段缩进 2 空格，嵌套子字段 4 空格，
空 map 写成 `{}`。这里只抽我们关心的标量与一层嵌套，不引入 YAML 依赖
（PyYAML 解析不了 `!u!129 &1` 这类 tag）。

用途：让"出包配置是否合规"变成可断言检查，而不是靠人肉 grep（V13 正文那三行命令）。
"""

from __future__ import annotations

import os
import re

DEFAULT_PATH = r"C:/workspaces/Client/ProjectSettings/ProjectSettings.asset"

_R_FIELD = re.compile(r"^(\s{2})([A-Za-z_][\w]*):\s*(.*)$")
_R_SUB = re.compile(r"^(\s{4})([A-Za-z_][\w]*):\s*(.*)$")


def _scalar(v: str):
    v = v.strip()
    if v == "{}":
        return {}
    if v in ("[]", ""):
        return {} if v == "{}" else v
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if re.fullmatch(r"-?\d+\.\d+", v):
        return float(v)
    return v.strip("'\"")


def parse(text: str) -> dict:
    """返回 {字段名: 标量 或 一层 dict}。"""
    out: dict = {}
    lines = text.splitlines()
    current: str | None = None
    for line in lines:
        m2 = _R_FIELD.match(line)
        if m2:
            name, val = m2.group(2), m2.group(3)
            if val.strip() == "":
                current = name
                out[name] = {}
            else:
                out[name] = _scalar(val)
                current = None
            continue
        m4 = _R_SUB.match(line)
        if m4 and current is not None:
            sub, val = m4.group(2), m4.group(3)
            bucket = out.get(current)
            if isinstance(bucket, dict):
                bucket[sub] = _scalar(val)
    return out


def load(path: str = DEFAULT_PATH) -> dict:
    with open(path, encoding="utf-8", errors="replace") as f:
        return parse(f.read())


def sub(settings: dict, field: str, key: str):
    """取一层嵌套值；空 map 或缺失都返回 None。"""
    v = settings.get(field)
    if isinstance(v, dict):
        return v.get(key)
    return None


def bundle_version(settings: dict) -> str | None:
    v = settings.get("bundleVersion")
    return str(v) if v not in (None, "") else None


def android_code(settings: dict) -> int | None:
    v = settings.get("AndroidBundleVersionCode")
    return v if isinstance(v, int) else None


def arch_name(bits: int) -> str:
    """Unity 的 AndroidTargetArchitectures 是位掩码。"""
    names = []
    if bits & 1:
        names.append("ARMv7")
    if bits & 2:
        names.append("ARM64")
    if bits & 4:
        names.append("x86")
    if bits & 8:
        names.append("x86_64")
    return "+".join(names) or f"未知({bits})"


def scripting_backend_name(v) -> str:
    return {0: "Mono", 1: "IL2CPP"}.get(v, f"未设置({v})")
