# U5 跨服排行 UI — 开发记录

> 阶段：U5（核心循环收尾）　日期：2026-11-22　纪律：只动新版 `bookskynet/ch13_palace` 与 `palaceclient`，不碰原版 trunk/Lovely。发布验证按用户要求延后。

## 1. 目标与边界

**设计口径**（`CLIENT_V2_DESIGN.md` §8.1 / §7.4 / `CROSS_SERVER.md` §4）：
- 只读列表 + 我的名次 + 灰度开关表现。
- 验收：两 zone 同榜（服务端 P0.5 已由 `test_cross` T1 验证）；**开关关闭时入口灰掉不报错**。

**实际落地范围**：
- 服务端 **零改动** —— `hub.lua` + `handler/cross.lua` + aid 16/17 在 P0.5 已完成并 30 断言验证。U5 只补客户端。
- 客户端新增 `CrossDomain` + `CrossPanels` + `RankView` 纯函数：把 `u.crossRank` 的 `ACTION_RES.result`（临时数据，不写 store）解析成可断言的视图模型。
- 关键点：现有 `List` 原语只吃 store map，排行是回执临时数据 → 用 **Core 纯函数解析 result → 视图模型**，Game 层只渲染，规则不进渲染层（延续 U4 结算页做法）。
- 灰度：`enabled=false` 时返回 `Disabled` 视图（含提示文案），Game 层灰掉入口、不弹错误框。

**不做（保持边界）**：跨服战 `settle`（仍占位）、提交排行分数的自动触发（本次只做手动提交按钮）、hub 多实例/Redis。

## 2. 基线（改造前实测）

| 项 | 基线 |
|---|---|
| 服务端 `make verify` | 500 PASS / 0 FAIL；reconcile 46/0（17:59 实测） |
| 客户端 `verify.py` | 8/8、161 项（U4 完成态） |
| 客户端 `verify.py --e2e` | 9/9 |
| Unity batchmode 编译 | 0 error（U4 完成态） |
| 生成物 | schema 26 actions / gamedata stage=10 shop=3 sign=7 online=3 |

## 3. 子任务表

| # | 子任务 | 验收凭据 | 状态 |
|---|---|---|---|
| S3-0 | 本文档 + 规则边界 | 基线记录 | ✅ |
| S3-1 | `RankView` 纯函数 + `CrossDomain`/`CrossPanels` | 单测：两 zone 同榜解析 / 灰度视图 / 我的名次 | pending |
| S3-2 | 注册 Cross 域 + Game 层排行页签 | verify 全过；灰度入口不报错 | pending |
| S3-3 | 全量回归 + 文档收尾 | 服务端/客户端门禁不回退、Unity 0 error | pending |

## 4. 问题归档

### P1 中文字体缺 14 字（U5 新文案）
- **现象**：`build_font.py --check` 报「字形缺失 14 个：刀图弹挨故暂案榜灰画白般视骂」，`verify.py` 字体关卡红。
- **根因**：字体子集按全源码字符集扫描生成；U5 新增文案（跨服排行/加载中/灰度/名次/战力…）含未收录汉字。部分缺字（刀/图/弹）是 U4 后未彻底重建的历史残留。
- **方案**：`python3 tools/build_font.py` 重建子集（213168 B / 915 字符），`--check` 通过。
- **预防**：凡在 Core/Game 新增中文字符串常量，提交前必跑 `build_font.py --check`；已列入 verify.py 固定关卡（U4 教训延续）。

### P2 Game 层缺 using 导致 Unity 编译失败（headless 抓不到）
- **现象**：Unity batchmode 报 `Main.cs: ListModel/ListItemModel/FieldModel 未找到类型`（3 处 ×2）。
- **根因**：U5 页签在 Game 层构造 `ListModel`，但 Main.cs 只有 `using Palace.Core.Wire/Runtime/UI.Render`，没有 `using Palace.Core.UI`；headless（dotnet test）只编译 Core/测试，看不到 Game 层，故 verify.py 8/8 全绿也漏掉。
- **方案**：Main.cs 补 `using Palace.Core.UI;`；重跑 batchmode 0 error。
- **预防**：凡改 Game 层（Main/Render/Transport/Storage），必须补一次 Unity batchmode 编译——这是 U2 已立的规矩，U5 再次验证其必要性。

### P3 verify.py 整体跑触发 SIGTERM（工具前台超时，非产品问题）
- **现象**：`python3 tools/verify.py` 在前台连续两次 `SIGTERM`（exit 1），但逐关单跑全过。
- **根因**：verify.py 串行跑 2 次 dotnet build + 1 次 dotnet test，累计耗时超过工具前台上限被杀；非门禁逻辑失败。
- **方案**：改用后台任务跑 verify.py，完整输出重定向到文件；结果与逐关一致。
- **预防**：客户端门禁一律后台跑；单关可用 `python3 tools/<脚本>` 前台快速定位。

## 5. 里程碑与验收凭据

| 子任务 | 状态 | 凭据 |
|---|---|---|
| S3-0 开发记录与基线 | ✅ | 基线 500 PASS/46 对账记录 |
| S3-1 RankView 纯函数 + Cross 域/面板 | ✅ | 166 项测试（+5），RankView 三态断言 |
| S3-2 注册 Cross 域 + Game 页签 | ✅ | verify.py 8/8；167 项（+6）；Unity batchmode 0 error |
| S3-3 全量回归 + 文档 | ✅ | verify.py --e2e 9/9；服务端不回退；设计文档 §8.1 + §19 |

**最终凭据**：
- 客户端 `verify.py` **8/8**；无头测试 **167 项**（基线 161 → +6 PanelU5）
- 客户端 `verify.py --e2e` **9/9**（含真服务端登录链路）
- Unity 2021.3 batchmode 编译 **0 error**（Game 层页签改动）
- 中文字体子集 213168 B / 915 字符（重建覆盖 U5 新文案）
- 服务端 `make verify` 500 PASS / reconcile 46/0（基线，未改动服务端）
- 两 zone 同榜由 P0.5 `test_cross` T1 验证；灰度开关由 T4 验证

**关键决策**：服务端零改动——U5 只补客户端 UI；排行临时数据用 Core 纯函数解析，不塞 store、不建专用 List 原语；灰度三态归一，入口灰掉不报错。

**下一步候选**：U6 M3 次要玩法（rank/gacha/home/errand 降级版），依赖核心循环已就绪。发布验证继续延后。
