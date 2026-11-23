"""roles 表结构静态检查 —— V07 配套。

不连数据库：只解析 .sql 文本。目的是让"表结构与创角需求是否对齐"变成可断言的检查，
而不是等联调时 `INSERT ... name` 报 `Unknown column` 才发现（台账 C-28）。

用法：
    python unity_client/v07_role_schema/check_schema.py                  # 检查 v2
    python unity_client/v07_role_schema/check_schema.py --file schema_v1.sql
    python unity_client/v07_role_schema/check_schema.py --diff           # v1 → v2 缺哪些列
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field

HERE = os.path.dirname(os.path.abspath(__file__))

# 创角/选角链路对 roles 表的最小要求（依据 V05 的契约覆盖度 + V07 竖切）
REQUIRED_COLUMNS = {
    "uid": "主键，账号维度",
    "name": "角色名，创角必填",
    "level": "等级，选角列表要显示",
    "profession": "职业，创角可选值",
    "gender": "性别，创角可选值",
    "version": "版本号，增量与乐观锁",
}

_R_COL = re.compile(
    r"^\s*`(?P<name>\w+)`\s+(?P<type>[A-Za-z]+)(?:\((?P<len>\d+)\))?"
    r"(?P<rest>.*?),?\s*$"
)
_R_UK = re.compile(r"UNIQUE\s+KEY\s+`?(\w+)`?\s*\(([^)]+)\)", re.I)
_R_PK = re.compile(r"PRIMARY\s+KEY\s*\(([^)]+)\)", re.I)
_R_KEY = re.compile(r"^\s*KEY\s+`?(\w+)`?\s*\(([^)]+)\)", re.I)


@dataclass
class Column:
    name: str
    type: str
    length: int | None
    not_null: bool
    default: str | None


@dataclass
class Schema:
    table: str = ""
    columns: dict[str, Column] = field(default_factory=dict)
    primary_key: list[str] = field(default_factory=list)
    unique_keys: dict[str, list[str]] = field(default_factory=dict)
    indexes: dict[str, list[str]] = field(default_factory=dict)
    charset: str = ""
    collation: str = ""


def parse_sql(text: str) -> Schema:
    """极简 CREATE TABLE 解析。只认本项目用到的语法，够用作 lint。"""
    s = Schema()
    m = re.search(r"CREATE TABLE(?:\s+IF NOT EXISTS)?\s+`?(\w+)`?\s*\((.*?)\)\s*ENGINE",
                  text, re.S | re.I)
    if not m:
        raise ValueError("未找到 CREATE TABLE ... ENGINE= 结构")
    s.table = m.group(1)
    body = m.group(2)

    for raw in body.split("\n"):
        line = raw.strip().rstrip(",")
        if not line or line.startswith("--"):
            continue
        if line.upper().startswith("PRIMARY KEY"):
            pk = _R_PK.search(line)
            if pk:
                s.primary_key = [c.strip().strip("`") for c in pk.group(1).split(",")]
            continue
        if line.upper().startswith("UNIQUE KEY") or line.upper().startswith("UNIQUE INDEX"):
            uk = _R_UK.search(line)
            if uk:
                s.unique_keys[uk.group(1)] = [c.strip().strip("`") for c in uk.group(2).split(",")]
            continue
        if line.upper().startswith("KEY ") or line.upper().startswith("INDEX "):
            k = _R_KEY.match(line)
            if k:
                s.indexes[k.group(1)] = [c.strip().strip("`") for c in k.group(2).split(",")]
            continue
        col = _R_COL.match(line)
        if col:
            rest = col.group("rest") or ""
            s.columns[col.group("name")] = Column(
                name=col.group("name"),
                type=col.group("type").upper(),
                length=int(col.group("len")) if col.group("len") else None,
                not_null="NOT NULL" in rest.upper(),
                default=(re.search(r"DEFAULT\s+('[^']*'|\S+)", rest, re.I).group(1)
                         if re.search(r"DEFAULT\s+('[^']*'|\S+)", rest, re.I) else None),
            )

    cs = re.search(r"CHARSET=(\w+)", text, re.I)
    co = re.search(r"COLLATE=(\w+)", text, re.I)
    s.charset = cs.group(1) if cs else ""
    s.collation = co.group(1) if co else ""
    return s


def lint(s: Schema, required: dict[str, str] | None = None) -> list[str]:
    """返回问题列表（空 = 通过）。规则都可解释，不自作主张。"""
    required = required if required is not None else REQUIRED_COLUMNS
    problems: list[str] = []

    for col, why in required.items():
        if col not in s.columns:
            problems.append(f"缺列 `{col}`（{why}）")

    if s.primary_key != ["uid"]:
        problems.append(f"主键应为 (`uid`)，实际 {s.primary_key}")

    if "name" in s.columns:
        c = s.columns["name"]
        if not any(v == ["name"] for v in s.unique_keys.values()):
            problems.append("`name` 没有唯一索引 —— 并发创角会出重名（不能靠先查再插）")
        if not c.not_null:
            problems.append("`name` 允许 NULL —— 空名角色会在选角列表里出现空白行")
        if not c.length or not (1 <= c.length <= 32):
            problems.append(f"`name` 长度 {c.length} 不合理（建议 1~32）")

    for name, c in s.columns.items():
        if not c.not_null and c.default is None and name != "updated_at":
            problems.append(f"`{name}` 可空且无默认值 —— 部分更新时会写成 NULL")

    if s.charset.lower() != "utf8mb4":
        problems.append(f"字符集应为 utf8mb4（当前 {s.charset or '未声明'}），否则中文名截断")

    if "version" in s.columns and s.columns["version"].type not in ("INT", "BIGINT"):
        problems.append("`version` 应为整数类型")

    return problems


def diff(v1: Schema, v2: Schema) -> tuple[list[str], list[str]]:
    """返回 (v1 缺的列, v2 新增的索引)。"""
    missing = [c for c in v2.columns if c not in v1.columns]
    new_idx = [k for k in {**v2.unique_keys, **v2.indexes}
               if k not in {**v1.unique_keys, **v1.indexes}]
    return missing, new_idx


def load(path: str) -> Schema:
    with open(path, encoding="utf-8") as f:
        return parse_sql(f.read())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="schema_v2.sql")
    ap.add_argument("--diff", action="store_true")
    args = ap.parse_args(argv)

    path = args.file if os.path.isabs(args.file) else os.path.join(HERE, args.file)
    s = load(path)
    print(f"表 `{s.table}`：{len(s.columns)} 列，主键 {s.primary_key}，"
          f"唯一键 {list(s.unique_keys)}，字符集 {s.charset}")

    if args.diff:
        v1 = load(os.path.join(HERE, "schema_v1.sql"))
        missing, new_idx = diff(v1, s)
        print(f"\nv1 → v2 需新增列 {len(missing)} 个：{', '.join(missing) or '无'}")
        print(f"需新增索引 {len(new_idx)} 个：{', '.join(new_idx) or '无'}")
        v1_problems = lint(v1)
        print(f"\nv1 体检：{len(v1_problems)} 个问题")
        for p in v1_problems:
            print(f"  - {p}")

    problems = lint(s)
    print()
    if problems:
        print(f"{os.path.basename(path)}：{len(problems)} 个问题")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"{os.path.basename(path)}：通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
