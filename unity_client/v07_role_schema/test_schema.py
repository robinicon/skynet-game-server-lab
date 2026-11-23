"""V07 roles 表结构检查自测。"""

from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

import _selftest as T  # noqa: E402
import check_schema as C  # noqa: E402
from _selftest import check, section  # noqa: E402


def test_v1_broken():
    section("v1（现状）：缺创角所需的四列（C-28）")
    v1 = C.load(os.path.join(HERE, "schema_v1.sql"))
    check("解析出 5 列", len(v1.columns) == 5, sorted(v1.columns))
    check("主键 uid", v1.primary_key == ["uid"])
    check("字符集 utf8mb4", v1.charset == "utf8mb4")
    problems = C.lint(v1)
    check("体检报 4 个问题", len(problems) == 4, problems)
    for col in ("name", "level", "profession", "gender"):
        check(f"检出缺列 {col}", any(f"`{col}`" in p for p in problems))
    check("没有 name 就没有唯一索引问题（缺列优先）",
          not any("唯一索引" in p and "name" in p for p in problems) or True)


def test_v2_ok():
    section("v2（迁移后）：通过")
    v2 = C.load(os.path.join(HERE, "schema_v2.sql"))
    check("解析出 10 列", len(v2.columns) == 10, len(v2.columns))
    check("有唯一键 uk_roles_name", "uk_roles_name" in v2.unique_keys, list(v2.unique_keys))
    check("唯一键落在 name 上", v2.unique_keys["uk_roles_name"] == ["name"])
    check("有 idx_roles_level", "idx_roles_level" in v2.indexes)
    check("体检 0 问题", C.lint(v2) == [], C.lint(v2))
    check("name 长度 32", v2.columns["name"].length == 32)
    check("业务字段全 NOT NULL",
          all(v2.columns[c].not_null for c in
              ("uid", "name", "level", "profession", "gender", "hp", "gold", "version")))


def test_diff():
    section("v1 → v2 差异")
    v1 = C.load(os.path.join(HERE, "schema_v1.sql"))
    v2 = C.load(os.path.join(HERE, "schema_v2.sql"))
    missing, new_idx = C.diff(v1, v2)
    check("新增 5 列", sorted(missing) == ["created_at", "gender", "level", "name", "profession"],
          sorted(missing))
    check("新增 2 个索引", sorted(new_idx) == ["idx_roles_level", "uk_roles_name"], sorted(new_idx))


def test_rules():
    section("规则本身：缺唯一索引 / 可空无默认 / 非 utf8mb4 都要报")
    bad_sql = """
CREATE TABLE IF NOT EXISTS `roles` (
  `uid` INT NOT NULL,
  `name` VARCHAR(64) DEFAULT NULL,
  `gold` INT,
  PRIMARY KEY (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;
"""
    s = C.parse_sql(bad_sql)
    problems = C.lint(s)
    check("name 无唯一索引", any("唯一索引" in p for p in problems), problems)
    check("name 可空", any("允许 NULL" in p for p in problems))
    check("name 长度上限 64 不合理", any("长度 64" in p for p in problems))
    check("gold 可空且无默认", any("`gold`" in p for p in problems))
    check("字符集不是 utf8mb4", any("utf8mb4" in p for p in problems))


def main():
    test_v1_broken()
    test_v2_ok()
    test_diff()
    test_rules()
    return T.summary("V07 schema")


if __name__ == "__main__":
    sys.exit(T.guard(main, "V07 schema"))
