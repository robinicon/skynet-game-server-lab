# v05_contract · 契约覆盖度矩阵

**对应篇目**：V05《契约覆盖度矩阵》｜**档位**：A 档

## 解决什么

把"界面需要什么数据"和"契约里有什么消息"对撞，输出缺口表。需求加了界面却忘了加协议，
就是台账 C-04 —— 靠人眼比对 `opcode_registry.yaml` 与 9 个 prefab 迟早会漏。

## 文件

| 文件 | 作用 |
|---|---|
| `ui_screens.json` | 界面 → 协议需求映射（**只记 prefab 文件名与职责，不含任何美术内容**） |
| `coverage.py` | 载入 registry，输出矩阵、通道占用、下一个可用 id、提案行 |
| `test_coverage.py` | 26 条断言：缺口正是那四条、提案 id 全空闲、id 进制解析 |

## 跑

```bash
python unity_client/v05_contract/coverage.py             # 盘点（rc 恒 0）
python unity_client/v05_contract/coverage.py --strict    # 有缺口 rc=1，可进 CI
python unity_client/v05_contract/coverage.py --propose   # 输出可贴进 registry 的行
```

## 实测输出（本仓库当前状态）

```
RoleSelect        选角   缺 1   [缺]CLI_ROLE_LIST_REQ
Character (List)  选角   缺 1   [缺]CLI_ROLE_LIST_RSP
RoleCreate        创角   缺 1   [缺]CLI_ROLE_CREATE_REQ
通道 CLI  占用 14 个  区间 0x0001~0x000E  下一个可用 0x000F
```

## 一个踩过的坑

YAML 会把 `id: 0x000D` 解析成整数 `13`。若再按十六进制重解析 `int("13", 16)`，
会静默算成 `19`，通道区间就从 `0x000E` 变成 `0x0014`、下一个可用 id 从 `0x000F` 变成 `0x000A`。
`as_int()` 与 `test_id_radix()` 专门守住这条 —— **静默错位的解析比报错更难查**。

## 证据边界

四条提案 opcode 与服务端 handler 均为**待实现**，本目录不声称已合入或已联调。
