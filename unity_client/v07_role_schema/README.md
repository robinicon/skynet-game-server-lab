# v07_role_schema · roles 表结构与迁移

**对应篇目**：V07《选角与创角补齐契约》｜**档位**：B 档

## 解决什么

`ch7_db` 的 `roles` 表只有 `uid / hp / gold / version`，**没有 `name`**（台账 C-28）。
创角做的第一件事就是插角色名，联调时会在 `Unknown column 'name'` 上停住。

## 文件

| 文件 | 作用 |
|---|---|
| `schema_v1.sql` | 现状（四列），保留用于算差异 |
| `schema_v2.sql` | 创角竖切所需结构 + 幂等迁移语句 |
| `check_schema.py` | 静态 SQL 解析与规则检查（**不连库**） |
| `test_schema.py` | 23 条断言：v1 缺 4 列、v2 通过、差异 5 列 2 索引 |

## 跑

```bash
python unity_client/v07_role_schema/check_schema.py            # 检查 v2
python unity_client/v07_role_schema/check_schema.py --diff     # v1 → v2 差异
python unity_client/v07_role_schema/check_schema.py --file schema_v1.sql
```

实测差异：新增列 `name, level, profession, gender, created_at`，新增索引
`uk_roles_name, idx_roles_level`。

## 三条设计取舍（写在 schema_v2 注释里）

1. **`name` 唯一索引兜并发**，不靠"先查再插"——那是竞态，和 ch7 的丢失更新同源。
2. **业务字段全 `NOT NULL` + `DEFAULT`**，避免部分更新把未提供的列写成 NULL
   （ch7_db 的 `D3.2` 就是这么丢的 gold）。
3. **`version` 留给乐观锁**，不与 `updated_at` 混用。

## 迁移的坑（已写进 SQL 注释）

MySQL 8 不支持 `ADD COLUMN IF NOT EXISTS`。存量行 `name` 会是空串，
**唯一索引在第二行就撞**，必须先 `UPDATE roles SET name = CONCAT('role_', uid) WHERE name = ''`
再建索引。这条不写清楚，迁移脚本一跑就跪。

## 证据边界

`schema_v2.sql` 是**待执行**的定案，未在 MySQL 上跑过。`check_schema.py` 只做静态检查，
不能替代 DDL 实跑。
