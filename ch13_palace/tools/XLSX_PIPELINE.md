# Excel 导表工具链设计

> 事实源从 JSON 迁移到 `conf/schema.xlsx`。Excel 表本身无执行含义，
> 由导表工具翻译成 Lua 配置，运行时用这些配置解读数据库抽象数据和路由消息。

## 1. 数据流

```
conf/schema.xlsx (Excel / WPS / LibreOffice 编辑)
    │  tools/gen_schema.py 读取（tools/xlsx.py 零依赖 OOXML 解析）
    ├──> generated/fields_generated.lua   字段 fid/类型/分区/持久化/复制策略
    ├──> generated/actions_generated.lua  aid ↔ 老 op + 参数名 + handler
    ├──> generated/errors_generated.lua   错误码
    └──> conf/schema.json                 可读镜像（仅审计，不参与运行）
              │
              ▼
      tools/check_schema.py 校验同步 → skynet 运行时 require generated/*
```

**关键纪律**：只编辑 Excel，不改 `generated/*`（会被覆盖）；每次改完跑 `make gen`，
提交前跑 `make check-schema`（已内嵌在 `make test` 里）。

## 2. Excel 工作簿结构

工作簿含 4 个 sheet，第一行为表头。

### 2.1 `fields` — 数据库抽象字段定义

| 列 | 含义 | 约束 |
|---|---|---|
| fid | 字段数字 ID | 正整数、全局唯一、**永不复用** |
| name | 字段名 | 唯一，Lua 标识符；业务代码用 `schema.get(state,name)` |
| type | 类型 | `int` / `number` / `string` / `bool` / `map` / `array` |
| partition | 所属分区 | `base` / `hero` / `item` / `mission` / `activity`（可增） |
| persist | 持久化策略 | `index` 索引列 / `blob` 随分区 / `lazy` 懒加载 / `derived` 派生不入库 / `transient` 不入库 |
| replicate | 复制策略 | `snapshot` 登录全量 / `delta` 增量 / `on_demand` 订阅 / `none` |
| note | 说明 | 自由文本 |

### 2.2 `actions` — 消息路由定义

| 列 | 含义 | 约束 |
|---|---|---|
| aid | 动作数字 ID | 正整数、唯一、**只增不改** |
| op | 老协议 op 字符串 | 唯一，如 `u.heroUpdateLv` |
| params | 参数名列表 | 逗号分隔；位置参数按此顺序解读为命名参数 |
| handler | handler 名 | `login` / `hero` / `item` / `view`（新增需同步白名单） |
| note | 说明 | 自由文本 |

### 2.3 `errors` — 错误码

| 列 | 含义 |
|---|---|
| name | Lua 常量名，如 `BAD_PASSWORD` |
| value | 数值，如 `-3` |
| note | 说明 |

### 2.4 `meta` — 元信息

| key | 值 |
|---|---|
| version | schema 版本，兼容扩展时 +1 |
| note | 自由说明 |

## 3. 工具实现

| 文件 | 职责 |
|---|---|
| `tools/xlsx.py` | 零依赖 XLSX 读写入库。读：解析 `[Content_Types]`/`workbook.xml`/rels/sheet XML，兼容 `inlineStr` 与 `sharedStrings`；写：生成最小合法 OOXML 包，字符串写为 `inlineStr`。列号 `A`/`BC` 与索引互转。 |
| `tools/make_xlsx.py` | 迁移引导工具：从 `conf/schema.json` 生成初始 `conf/schema.xlsx`；`--stdout` 预览四表；`--force` 覆盖。 |
| `tools/gen_schema.py` | 主导表工具：读 Excel → 校验 → 生成 3 个 Lua 文件 + JSON 镜像。确定性输出。 |
| `tools/check_schema.py` | 一致性门禁：重新计算期望内容并与磁盘比较，任何漂移非零退出。 |

**为什么不用 openpyxl**：WSL Ubuntu 26.04 未预装 openpyxl/pandas，工具链设计为
`python3` 标准库即可运行（`zipfile` + `xml.etree.ElementTree`），不引入外部依赖，
CI / 新环境可直接跑。写出的 xlsx 是标准 OOXML，Excel/WPS/LibreOffice 均可打开编辑。

## 4. 命令

```bash
# Windows Git Bash 调 WSL
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc 'cd /mnt/c/workspaces/bookskynet && make -C ch13_palace <target>'
```

| 目标 | 作用 |
|---|---|
| `make xlsx-preview` | 打印 Excel 四表内容，不修改任何文件 |
| `make xlsx-init` | 仅当 `schema.xlsx` 丢失时，从 JSON 镜像重建并生成 Lua |
| `make gen` | 从 Excel 重新生成 Lua + JSON 镜像 |
| `make check-schema` | 校验 Excel 与生成物同步 |
| `make test` | 自动执行 gen + check-schema + 4 个测试服务 |

## 5. 校验规则（gen/check 都会执行）

1. fid / name / aid / op 各自唯一
2. type / persist / replicate 必须在枚举内
3. handler 必须在白名单内
4. errors 的 value 必须是整数
5. 生成物内容与 Excel 推导结果字节级一致（check-schema）

## 6. 实测凭据

- 2026-11-21（阶段 0）：`schema check: 12 fields, 5 actions, 7 errors, xlsx in sync with 3 generated files + mirror` + `=== TOTAL: 88 PASS, 0 FAIL ===`，rc=0。
- 2026-11-22（阶段 5）：`gamedata check: hero=4 exp=79 surmount=16 week=16 item=7 mission=3, lua + mirror in sync` + `schema check: 13 fields, 15 actions, 7 errors` + `=== TOTAL: 327 PASS, 0 FAIL ===`，rc=0。
- 管道穿透实验：向 Excel `fields` 临时追加 `fid=13 test_field`，`make gen` 后 `fields_generated.lua` 出现该字段；恢复原表后 `check-schema` 重新一致。

## 7. 第二本工作簿：`conf/gamedata.xlsx`（阶段 5）

`schema.xlsx` 定义**载体**，`gamedata.xlsx` 定义**内容**。两者同一套管道、同一套纪律：

| Sheet | 列 | 用途 |
|---|---|---|
| `hero` | templateId / name / quality / maxLv | 英雄模板 |
| `hero_exp` | lv / exp | 升到 lv+1 所需经验（`hero_max_lv` = 最大 lv + 1） |
| `hero_surmount` | templateId / advanceLv / lvLimit / costItem / costNum | 加官门槛与消耗 |
| `hero_week` | templateId / limitLv / breakLvLimit / costItem / costNum | 进爵门槛与消耗 |
| `item` | templateId / name / kind / value / sellPrice / stack | 道具定义（kind: elixir/material/gold/silver） |
| `mission` | missionId / type / target / rewardItem / rewardNum | 任务目标与奖励 |
| `meta` | key / value | 版本等元信息 |

生成物：`generated/gamedata_generated.lua` + `conf/gamedata.json` 镜像。
运行时访问层：`shared/gamedata.lua`（`hero_need_exp` / `surmount` / `week` / `item` / `mission` / `elixir_tiers`）。

`gen_gamedata.py --check` 额外校验引用完整性：加官/进爵的 costItem、任务的 rewardItem 必须存在于 `item` 表；
重复 id、非法 kind、空经验表都会直接失败。该校验已挂到 `make check-schema` 前置。

命令：

```
make -C ch13_palace gamedata          # 生成 Lua + 镜像
make -C ch13_palace check-gamedata    # 同步校验（引用完整性也在这一步）
make -C ch13_palace gamedata-preview  # 预览各表
```

## 8. 与后续阶段的关系

- 阶段 5（动作批量迁移，进行中）：新增 action 只改 `schema.xlsx` 的 actions sheet + 新增一个 `service/handler/<domain>.lua`；数值改 `gamedata.xlsx`。导表后 `schema.action()` 与 `gamedata.*` 立即可见，不需要改路由代码。
- 阶段 2（MySQL 驱动）：`fields` 的 persist 列决定写入 `entity_field` 还是 `entity_partition`，导表即生效。
- 若要支持客户端协议文件导出（opcode），可在工作簿增加 `client_ops` sheet 并扩展 `gen_schema.py`，不影响现有表。
