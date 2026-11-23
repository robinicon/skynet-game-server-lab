# U4 战斗与关卡 — 开发记录

对应 `CLIENT_V2_DESIGN.md` §6.1 / §8.1 的 U4 行（服务端 7~11 + 客户端 6~8 人日）。
服务端在 `bookskynet/ch13_palace`，客户端在 `palaceclient`。**不碰原版 trunk / Lovely。**

---

## 1. 目标与基线

**目标**：MR 核心循环补齐 —— `stage`/`fight`/`shop`/`reward` 四批次 + 客户端战斗结果页。
验收口径（设计 §8.1）：**关卡 10 连打，掉落/经验与样本一致**。
不做逐帧战斗（WebGL 无多线程 → 服务端结算是物理必然，D2）；不做跨服战（hub.settle 仍占位）。

**改造前基线（2026-11-22 实测）**：
- 服务端 `make verify` = **427 PASS / 0 FAIL**，reconcile **23 cases / 0 failed**（P0.5 后）。
- `gamedata check`：hero=4 exp=79 surmount=16 week=16 item=7 mission=3，lua + mirror in sync。
- `schema check`：13 fields, 17 actions, 7 errors，同步。
- 客户端 `verify.py` 8/8、`--e2e` 9/9；Unity 2021.3.15f1c1 在位（`/c/Program Files/Unity/Hub/Editor/2021.3.15f1c1`），dotnet 8.0.428。

---

## 2. 子任务表

| 子任务 | 内容 | 凭据 | 状态 |
|---|---|---|---|
| S2-0 | 本文档 + 样本规则定稿 | 规则口径写入 §3 | ✅ |
| S2-1 | 导表：gamedata 加 stage/shop/sign/online 表；schema 加 aid 18~26 | 10+3+7+3 表、26 actions；两 check 全过 | ✅ |
| S2-2 | 四个 handler：stage/fight/shop/reward | 7 个 lua 语法自检全过 | ✅ |
| S2-3 | `test/test_u4.lua`：10 连打等断言 | `make test-u4` **73 PASS / 0 FAIL** | ✅ |
| S2-4 | 对账样本 stage/fight/shop/reward.json | `make reconcile` **46 cases / 0 failed**（23→46） | ✅ |
| S2-5 | 客户端：生成物 + 三域 + 结算页 + 7 批夹具 | `verify.py` **8/8**、161 项；Unity batchmode 0 error | ✅ |
| S2-6 | 全量回归 + 文档收尾 | 服务端 500/0 + 46/0；客户端 8/8、161 项、--e2e 9/9；Unity 0 error | ✅ |

---

## 3. 样本规则定稿（先规则，后代码）

工程约定（见 `make_gamedata_xlsx.py` 头注）：数值是 authored demo content，
每条对账用例的 `derivation` 记录该期望从哪条规则推出。U4 全部采用**确定性数值**，
不用真随机 —— 这样结果可复现、可回放对账，也符合 §686"最终值以服务端返回为准"。

### 3.1 字段载体决策（关键）
**不新增 schema field。** 理由：加 field 会改变 SNAPSHOT/初始字段集，冲击既有 23 条回放对账基线
（U2 的 `seed_snapshot` 从播种后完整实体取全部 `replicate != none` 字段）。
U4 的运行时进度态全部塞进现有 map 字段：

| 数据 | 载体 | 键 |
|---|---|---|
| 关卡已通关最高关 | `activity`（fid 9, map, on_demand） | `activity.stage.clearMax` |
| 战斗战报（最近一次） | `activity` | `activity.fight.last` |
| 签到天数 / 最后签到日 | `activity` | `activity.reward.signDay` / `lastSign` |
| 在线累计分钟 / 已领档位 | `activity` | `activity.reward.onlineMin` / `onlineClaimed` |

`activity` 是 `replicate=on_demand`，客户端 U4 面板需订阅 activity 分区（复用 U2 的 routes 预加载机制）。

### 3.2 stage（关卡）
- `stage` 表 10 关：`stageId`(1..10), `needLevel`, `needPower`, `exp`, `gold`, `dropItem`, `dropNum`。
- `u.stageInfo` → 返回 `{ clearMax, next = {stageId, needLevel, needPower, exp, gold, drop...} }`（只读）。
- `u.stageChallenge(stageId)`：
  - 校验 `stageId == clearMax + 1`（必须逐关推进，不能跳关）→ 否则 `stage_locked`；
  - 校验 `level >= needLevel` → 否则 `level_too_low`；
  - 成功：`clearMax = stageId`，`exp/gold` 加到角色（经验折算：本批次先把 exp 作为独立计数存 `activity.stage.exp`，不接入英雄经验曲线，避免与 U2 养成分流），道具掉落进 `bag`。
  - result 返回 `{ win=true, stageId, exp, gold, dropItem, dropNum }`。
- `u.stageSweep(stageId, times)`：仅对已通关关卡（`stageId <= clearMax`）扫荡，按 times 倍发奖励；`times<1` 或关卡未通 → 失败。

### 3.3 fight（战斗，结算版）
- `u.fightStart(stageId)` → 返回确定性 `{ seed, power, needPower, canWin }`：
  - `seed = stageId * 1000 + 战力`（由关卡与已养成战力派生，非随机，可复现）；
  - `power` 由 `heroes` 求和：`Σ (tpl.quality * 10 + lv * 5 + advance * 2 + limit)`，无英雄时 power=0；
  - `canWin = power >= needPower`。
- `u.fightSettle(stageId)` → 服务端权威结算：复用 `canWin` 判定；胜则调用与 `stageChallenge` 相同的奖励逻辑（发 exp/gold/drop + 推进 clearMax），败只返回 `{ win=false }` 不改状态。战报写 `activity.fight.last = { stageId, seed, power, needPower, win }`。
- 与 stage 的分工：`challenge` 是"直接过关"的便捷路径，`fightStart+Settle` 是"先看战力再打"的完整路径；两者共用 `settle_win` 内部函数，避免规则双写。

### 3.4 shop（商店）
- `shop` 表货品：`goodsId`, `itemId`, `currency`(gold/silver), `price`, `limit`（0=不限）。
- `u.shopList` → 返回当前货品列表（只读，含已购数从 `activity.shop.bought` 取）。
- `u.shopBuy(goodsId, count)`：
  - 校验 count>=1、货品存在、限购未超；
  - 货币够 → 扣货币 + 背包加道具，记 `activity.shop.bought[goodsId] += count`；
  - 货币不足 → `gold_not_enough`/`silver_not_enough`，不改状态。

### 3.5 reward（签到 / 在线）
- `sign` 表 7 天奖励（day→itemId/count），`online` 表档位（minutes→itemId/count）。
- `u.rewardSign(day)`：`day` 为签到日(1..7)，服务端校验 `day == signDay+1`（`signDay=7` 时下一天为 1 循环）；
  同日重复领（`day == signDay`）→ `already_signed`，跳日 → `sign_day_mismatch`。
  由客户端声明签到日而非读系统时间，保证回放对账可复现；真实接入时由服务端日期源替换参数校验。
- `u.rewardOnline(minutes)`：校验 `activity.reward.onlineMin >= minutes` 且该档位未领 → 发奖并标记 `onlineClaimed[minutes]=true`。

### 3.6 错误码
沿用 schema 外业务码 `-200` + `result.reason`（与 U2 一致，不做白名单）。

---

## 4. 问题归档

### P6 客户端 4 项门禁同时失败（3 个独立缺陷）
- **现象**：`verify.py` 中字体、Core 编译、Headless 编译、dotnet test 四项 FAIL。
- **根因**：
  1. `gen_cs.py` 新增的局部变量 `stage` 被既有 surmount/week 生成块的 `for stage in ...` 覆盖（Python for 变量是函数级作用域）→ `sorted(stage)` 拿到 int；
  2. `StageNav.NextFromResult` 对 `JsonValue`（struct）用了 `== null`；`RewardPanels` 缺 `using Palace.Core.Wire`；
  3. 新增中文字符（商店/关卡/签到等）超出字体子集 → 字形缺失 17 个；
  4. `GameClientTests` 硬编码域数量 5，新增三域后失败（同 P0.5 `test_schema` 教训）。
- **方案**：新表变量改名 `stages_data` 等避开循环变量；`== null` 改 `.IsNull`、补 using；重建字体子集（209568B/901 字符）；域数量断言改下界 + 具名校验。
- **预防**：Python 生成器新变量不用单函数名（尤其 `stage`/`item` 这类常见循环变量）；C# struct 判空用 `.IsNull`；任何"数量 == N"断言都改下界 + 具名。

### P4 客户端回放夹具缺 U4 四批（接入遗漏）
- **现象**：服务端 46 条对账全过，但客户端 `capture_replay.py` 仍只导出 hero/item/mission 三批。
- **根因**：夹具导出与 ReplayTests 都有硬编码 batch 清单，加批次时漏改。
- **方案**：`BATCHES` 与 `TestCase` 同步加 stage/fight/shop/reward，重新导出 7 批夹具；客户端回放 161 项含新增 4 批。
- **预防**：把 batch 清单做成单一事实源（下阶段可优化），或加断言"夹具批次数 == 服务端 samples 数"。

### P1 T7 扫荡"未通关关卡"断言失败（测试 setup 缺陷，非产品 bug）
- **现象**：`test_u4` T7 期望 `sweep stage5` 返回 `stage_not_cleared`，实得 `reason=nil`（成功）。
- **根因**：T4 的 10 连打已把 `clearMax` 推到 10，stage5 此时是已通关关卡，扫荡本就应成功。测试前置状态与设计意图矛盾。
- **方案**：T7 前用 `set_fields` 把 `activity.stage.clearMax` 重置为 2，再扫荡 stage5。
- **预防**：写"失败路径"断言时必须显式构造触发该失败的前置状态，不能依赖前序成功用例留下的状态。

### P3 fight 对账样本 gold 期望写错（样本缺陷，非产品 bug）
- **现象**：`fight_replay_old_stage_no_rollback` 期望 gold=50，实得 70。
- **根因**：把 stage1 的 gold=50 误套到重打 stage3 的用例；stage3 gold=40+10*3=70。
- **方案**：修正样本 expect 为 70，derivation 补上公式。
- **预防**：对账期望值一律按公式现算并在 derivation 写明，不从前一条用例复制。

### P2 首次 `make test-u4` 被 SIGTERM（rc=143，WSL 偶发）
- **现象**：服务启动到 login 后进程被 SIGTERM，无 TOTAL 输出；重跑即过。
- **根因**：WSL 会话/tee 管道的偶发信号（与 P0.5 的 rc=-9 同类环境噪声），非产品逻辑。
- **方案**：重跑一次即可；门禁以重跑稳定结果为准。
- **预防**：后续接入 CI 时给 skynet 启动加重试或改用文件重定向。

---

## 5. 里程碑（2026-11-22 收尾）

- **达成**：MR 核心循环闭环补齐 —— P0 WS / P0.5 跨服排行 / U0 骨架 / U1 登录 / U2 三玩法 / U3 离线 / U4 战斗关卡全部落地。
- **服务端**：`make verify` **500 PASS / 0 FAIL**（改造前 427，+73 = test_u4）；reconcile **46 cases / 0 failed**（改造前 23，+23 = 四批样本）；gamedata 26 表行、schema 26 actions 全同步。
- **客户端**：`verify.py` **8/8**、无头 **161 项**（改造前 152，+9）、`--e2e` **9/9**；7 批真服务端 wire 夹具；Unity batchmode 0 error；字体 209568B/901 字符。
- **关键决策**：U4 进度态复用 activity map、不新增 schema field，保护既有回放基线；战斗数值全确定性、服务端权威；stage 与 fight 共用 award 单点。
- **纪律**：所有改动仅在 `bookskynet/ch13_palace` 与 `palaceclient`，原版 `palaceserver/trunk` / `Lovely` 受跟踪文件零改动。
- **下一步候选**：U5 跨服排行 UI（2~3 人日，P0.5 + U4 依赖均已就绪）→ U6 M3 → U7 表现打磨。发布验证链（wasm 出包 / 主包≤4MB / 真机四 flow / OFL 字体 / 备案域名 AppID）仍按用户要求延后。
