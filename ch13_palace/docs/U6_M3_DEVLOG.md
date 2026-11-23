# U6 M3 次要玩法 — 开发记录

> 阶段：U6（rank/gacha/home/errand 降级版）　日期：2026-11-22　纪律：只动新版 `bookskynet/ch13_palace` 与 `palaceclient`，不碰原版 trunk/Lovely。发布验证按用户要求延后。

## 1. 目标与边界

**设计口径**（`CLIENT_V2_DESIGN.md` §6.2 / §8.1 / P1 玩法表）：
- `rank`（本服只读聚合）、`gacha`（概率表+保底）、`home`（简化，不做摆件/寻路）、`errand`（简化，不做货架/加速）。
- 验收："各自 flow"跑通。原服这四块是 P2 重灾区（经营 39 op、家园 15 op、抽卡演出 4 窗口），新版只还原"有状态的规则"，不还原演出与运营外壳（决策 R1/R5）。

**降级原则**：确定性、服务端权威、无真随机、复用既有设施；数值为 authored demo content，由对账样本 derivation 逐条记录。

## 2. 四玩法规则定稿（本次权威口径）

### 2.1 rank（本服排行，aid 27 `u.rankList`）
- **架构决策 D-U6-1**：本服排行**复用 P0.5 的全局 `hub` 服务**，用独立 rankKey 前缀 `local.power` 与跨服榜隔离（单机部署 gid 均为 1，靠 key 区分）。不新增服务、不加 db 全服遍历命令（db 是薄代理，无 entities 语义）。
- 提交源：战力 `zhanli`（Fields.Zhanli）。`rankList` 先把自己的战力推给 hub，再查 `local.power` 第一页，返回降序 rows + me。
- **写入路径 D-U6-1b**：走 hub 新增的 `upsert(rankKey, uid, name, score)`，**不走** `submit` 的 (sid, seq) 幂等门。原因：本服榜是单实例权威，分数不是跨服聚合出来的；用秒级 `seq` 提交会出现"同一秒内战力变化被当 duplicate 丢弃"。跨服榜仍走 `submit`（需要乱序/重复语义），两者共用 bucket 与开关判定。
- 结果：`{ ok, rows=[{uid,name,score,rank}], me, rev }`；不写玩家 state（与 cross 同）。

### 2.2 gacha（抽卡，aid 28 `u.gachaDraw`）
- 配表 `gacha`：{tpl, weight} 四档（含一个稀有档）。按 weight 做确定性选择。
- **确定性随机 D-U6-2**：LCG（`seed = (drawSeq * 1103515245 + 12345) mod 2^31`），`drawSeq` 存 `activity.gacha.draws`（每次+1）。同 seed 必同结果，可复现对账。无真随机（符合 U4 纪律与 §4.5）。
- **保底 D-U6-3**：连续 9 抽未出稀有档时，第 10 抽强制稀有（`activity.gacha.pity` 计数）。出稀有后清零。
- 扣金币（每次 `cost`，配表 meta），发英雄/道具到 bag；结果 `{ ok, tpl, rare, pity, cost }` 写 changes。

### 2.3 home（家园，aid 29 `u.homeInfo` / 30 `u.homeUpgrade`）
- 配表 `home`：{level, upgradeGold, produceItem, produceNum} 主城建筑 1~5 级。
- `homeInfo` 只读当前等级与可领产出；`homeUpgrade` 扣金币升 1 级（服务端校验等级上限/金币）。
- 进度存 `activity.home = { level, harvested }`；不做摆件/寻路（降级）。产出领取用 `homeUpgrade` 顺带结算旧等级产出（避免再加 action）。

### 2.4 errand（办差，aid 31 `u.errandList` / 32 `u.errandClaim`）
- 配表 `errand`：{id, gold, itemId, itemNum} 三档差事。
- `errandList` 只读可选差事与已完成标记；`errandClaim` 领取一档奖励（发金币+道具）。
- **降级 D-U6-4**：不做计时/加速派遣——"派遣即完成"，领取即发奖；重复领取防护存 `activity.errand.claimed[errandId]`。

### 2.5 共同约束
- 运行时进度全部复用 `activity` map（fid 9）子键；**不新增 schema field**（保护 23+23 条回放基线）。
- 进度子键：activity.gacha / activity.home / activity.errand；rank 不写 state。
- 发奖货币/道具路由复用 `shared/award.lua` 语义；金币字段 gold、背包 bag。

## 3. 基线（改造前实测）

| 项 | 基线 |
|---|---|
| 服务端 `make verify` | 500 PASS / 0 FAIL；reconcile 46/0 |
| 客户端 `verify.py` | 8/8、167 项（U5 完成态） |
| 客户端 `verify.py --e2e` | 9/9 |
| Unity batchmode 编译 | 0 error |
| 生成物 | schema 26 actions / gamedata stage=10 shop=3 sign=7 online=3 |

## 4. 子任务表

| # | 子任务 | 验收凭据 | 状态 |
|---|---|---|---|
| S4-0 | 本文档 + 四玩法规则定稿 | 规则口径写入 §2 | ✅ |
| S4-1 | 导表：gamedata 加 gacha/home/errand；schema 加 aid27~32 + handler | make gen + 两 check | ✅ 32 actions |
| S4-2 | 四 handler：rank/gacha/home/errand + LCG 随机模块 | 语法自检 + 契约 | ✅ |
| S4-3 | `test/test_u6.lua` + make test-u6 | PASS/0 FAIL | ✅ 51/0 |
| S4-4 | 对账样本四批 | make reconcile 扩量全过 | ✅ 63/0 |
| S4-5 | 客户端四表+四域+四页签+夹具10批 | verify.py 全过 + Unity 0 error | ✅ 183 项 / 8/8 |
| S4-6 | 全量回归 + 文档收尾 | 服务端/客户端门禁+记忆 | ✅ |

## 5. 问题归档

### P1 抽卡权重表 pairs 遍历顺序不确定（确定性隐患）
- **现象**：gacha handler 初版用 `pairs(gd.gacha_tiers())` 构造权重表，Lua 表遍历顺序不保证。
- **根因**：`pick_weighted` 按 tiers 顺序做权重累加区间判定，顺序漂移会让同一 rng 落到不同 tpl——跨进程/对账样本不可复现，违背 D-U6-2"确定性"承诺。
- **方案**：构造后 `table.sort(tiers, a.key < b.key)`，固定累加区间；样本 derivation 用 tpl 升序口径。
- **预防**：任何"遍历表做累加/选择"的确定性逻辑，先排序再算；禁止依赖 pairs 顺序。

### P2 test_u6 服务无 `skynet.dispatch`/`skynet.start`，main 的 call 永久挂住
- **现象**：`make test-u6` 只打出 `LAUNCH snlua test_u6` 就再也不动，没有报错、没有 FAIL，直到 timeout。
- **根因**：测试文件只 `return M`，漏了文件末尾的 `skynet.dispatch("lua", ...)` + `skynet.start(...)`。服务起来了但没人处理 `run` 命令，`main.lua` 的 `skynet.call` 永远等不到回执（skynet 里"没人 ret"就是挂住，不是报错）。
- **方案**：补齐 dispatch/start，并给 `run` 套 `xpcall + debug.traceback`：崩了也 ret 一个 `{pass=0,fail=1}` 并把堆栈写进日志，避免"静默挂死"这种最难查的形态。
- **预防**：新测试服务照抄 `test_u4.lua` 的文件尾；单测跑不进时先看"有没有 LAUNCH 之后无输出"。

### P3 用了不存在的 `skynet.kill`
- **现象**：补齐 dispatch 后 test_u6 崩在 `attempt to call a nil value (field 'kill')`，整条 run 失败（0 PASS/1 FAIL）。
- **根因**：本仓库 skynet 版本没有 `skynet.kill`（只有 `skynet.killthread`）。既有测试从未销毁 agent，所以一直没暴露。
- **方案**：测试内不做显式销毁——进程退出即回收；agent 侧本来就有 `suspend` 负责落盘退出。
- **预防**：调用 skynet API 前先 `grep` 本地 `lualib/skynet.lua`，别按记忆写。

### P4 errand 货币类奖励覆盖固定奖励（对账抓到）
- **现象**：`errand_claim_id3_gold_kind` 期望 gold=1300，实测 1000。
- **根因**：`changes.gold = gold + conf.gold` 先写入固定奖励，随后货币类道具走 `changes["gold"] = ctx.get("gold") + value*num`——用**旧状态**起算，把前一笔覆盖掉。
- **方案**：同类字段一律"叠加在 changes 已有值上"：`changes[k] = (changes[k] or ctx.get(k) or 0) + delta`。shop（金币买金币类货品）、reward（一次发奖多笔同类货币）同类隐患一并修掉。
- **预防**：handler 里写 `changes[动态键]` 时，必须假定该键可能已被前一步写过；`test_u6` 加 T8b 锁回归。

### P5 数字键 map 的 JSON 形状随数据漂移
- **现象**：`activity.errand.claimed` 在只有一个键时落成 `[true]`（数组）、两个不相邻键时落成 `{"1":true,"3":true}`（对象），对账按点路径断言直接取不到。
- **根因**：`json.is_array` 判定"键恰好是 1..n 连续"，`claimed`/`bought`/`onlineClaimed` 这类 id 键 map 长度一变形状就变——同一逻辑结构两副线形，客户端与快照都要兼容两套。
- **方案**：`progress.as_object(map)` 显式打 `json.object` 标记；`deep_copy` 保留该标记（否则 `with_section` 拷贝会把标记丢掉）。
- **遗留**：对账样本里仍避免按数字键断言 `claimed`（回放输出会再编一次 JSON，数组下标语义与点路径不同），改由 `errand_duplicate_claim` 反向验证防重。

## 6. 里程碑

| 项 | 结果 |
|---|---|
| 服务端 `make verify` | **551 PASS / 0 FAIL**；reconcile **63/0**（+17：rank3/gacha4/home5/errand5） |
| `make test-u6` | **51 PASS / 0 FAIL** |
| schema | 13 fields / **32 actions** / 7 errors，三层门禁同步 |
| 客户端 `verify.py` | **8/8 全过**，dotnet 测试 **183 项**（U5 时 167） |
| 客户端 `verify.py --e2e` | 9/9（headless 46 PASS） |
| Unity batchmode | 0 error（域 13 个：login/ui + 三玩法 + U4 三域 + cross + U6 四域） |
| 回放夹具 | 11 批 / **63 用例**，客户端与服务端同一份 expect |

## 7. 客户端落地清单（U6）

| 层 | 文件 | 说明 |
|---|---|---|
| 生成物 | `Core/Config/{Actions,GameData}.cs` | gen_cs 扩 gacha/home/errand 三表 + `GachaCost/GachaPity/HomeMaxLevel` 常量 |
| 文案 | `Core/UI/TableText.cs` | gacha/home/errand 三个 case，未知键回退不崩 |
| 取值 | `Core/UI/PanelSpec.cs` / `PanelBuilder.cs` | 新增 `FieldSource.OfTableKey`：单页 Detail 按**常量键**查表（差事奖励），界面不重抄数值 |
| 本服榜 | `Core/Domain/Rank/*` | 复用 U5 的 `RankView`（回执结构一致），只换不可用提示 |
| 寻访 | `Core/Domain/Gacha/*` | `GachaView` 翻"稀有/保底/重复返还"文案；花费与保底线读配表常量 |
| 家园 | `Core/Domain/Home/*` | `HomeView.ToDetailModel`：等级/下一级花费/产出/金币；满级**不给按钮**而不是点下去报错 |
| 办差 | `Core/Domain/Errand/*` | `ErrandView.ToListModel` 回执驱动列表；确认页参数取行键 |
| 组合根 | `Core/Runtime/GameClient.cs` | 注册四域 + `QueryLocalRank/DrawGacha/QueryHome/UpgradeHome/QueryErrands` |
| 渲染胶水 | `Game/Main.cs` | 四页签 + `Loading()` + `ShowResultDialog()`（弹 Core 拼好的结论，不弹"操作成功"） |
| 测试 | `build/PalaceCore.Tests/PanelU6Tests.cs` | 12 组：配表/查表/三视图解析/域注册/面板动作参数 |
