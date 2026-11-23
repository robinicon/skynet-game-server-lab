# ch13_palace 逐一落地计划

> 纪律：每个阶段都必须有**可复跑的 WSL 命令 + 明确通过标准**；没有验收凭据不算完成。
> 所有命令在 WSL Ubuntu 内执行；从 Windows Git Bash 调用时加 `MSYS_NO_PATHCONV=1`。

```
# Windows Git Bash 统一入口
MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc 'cd /mnt/c/workspaces/bookskynet && make -C ch13_palace test'
```

---

## 阶段 0：契约基座（已完成）

**交付**：工程骨架、schema 单一事实源、生成器与校验器、4 个测试服务。

**文件**：
`conf/schema.xlsx`（Excel 事实源）、`conf/schema.json`（可读镜像）、`tools/{xlsx,gen_schema,check_schema,make_xlsx}.py`、`generated/*.lua`、
`shared/{schema,message,json,testutil}.lua`、`service/{db,login,agent}.lua`、`main.lua`、`runtime.lua`、`Makefile`。

**验收**：
```
make -C ch13_palace test
```
通过标准：`schema check: 12 fields, 5 actions, 7 errors, xlsx in sync with 3 generated files + mirror` + `=== TOTAL: 129 PASS, 0 FAIL ===` + rc=0（阶段 1 完成后总数，原基线的 88 PASS 仍全部包含在内）。

**人日**：2~3（已投入）。

---

## 阶段 1：TCP 网关与 legacy 协议接入（已完成）

**目标**：现有客户端不改一字节，能连到新服务端走完登录与动作。

**交付**：
- `service/gated.lua`：`snax.gateserver + netpack`，服务名 `gated`（避开 skynet 内置 `gate`）。
- 帧格式：`2 字节大端长度 + legacy JSON + 4 字节大端 session`，复用 `shared/json.lua`。
- 首包 `u.login`/`u.create` → LOGIN 鉴权 → `find_entity_by_account` 复用或创建实体 → 创建 agent 绑定 fd → 回登录包 + `u.snapshot`。
- 后续包：`normalize_in` → `agent.dispatch` → `to_legacy` → 回包；delta 嵌在 `params.delta`（独立 `u.delta` 留到阶段 4）。
- 错误路径：已登录连接未知 op 回 `-100` 不关连接；首包非法回 `-100` 后关闭。
- `test/gateclient.lua`（阻塞 TCP 客户端）+ `test/test_gate.lua`（41 断言，6 组用例）。
- `main.lua` 启动网关；`runtime.lua`/`conf/skynet.conf` 增加 `gate_address`/`gate_port`/`maxclient`/`backlog`；`Makefile` 默认 `TARGET` 纳入 `test_gate`。

**验收（实测）**：
```
make -C ch13_palace test-one T=test_gate
```
结果：`=== TOTAL: 41 PASS, 0 FAIL ===`，rc=0。含「老协议 op 进 → 老协议 op 出」「未知 op 返回 -100」「两包连续写入各自按 session 回应」「重连复用实体不重置」。

**修复记录**：首包非法路径曾在清理 `logining` 后才发错误帧，被 `send_wire` 存活守卫吞掉；改为先发帧再清状态。`agent.lua` 补 `afk` 占位以消除断线通知噪音（阶段 3 扩展为 suspend/resume）。

**人日**：3~4（已投入）。

---

## 阶段 2：持久化驱动切换（内存 → MySQL）（已完成）

**目标**：验证抽象存储可以在不改业务契约的前提下换后端。

**交付**：
- `clib/mysql.c` + `clib/Makefile`：同步 MySQL C 扩展（`connect/query/exec/insert_id/escape/close`），产物 `clib/mysql.so`。**未改动 skynet 子模块**，通过 `lua_cpath` 加 `./clib/?.so` 加载。同步调用合理，因为 db 服务本就是串行单点。
- `conf/ddl.sql`：6 张表（account / entity / entity_partition / entity_field / event_log / leaderboard_projection），驱动 init 时幂等建表（注意 `partition` 是 MySQL 保留字，需反引号）。
- `shared/db_driver_memory.lua`（阶段 0 逻辑平移，作对照）与 `shared/db_driver_mysql.lua`：实现**完全相同的方法契约**（init/create_account/get_account/create_entity/find_entity_by_account/load/set_fields/save/flush/reset/stats/driver_name）。
- `service/db.lua` 改为驱动分发的薄层，按 `CH13_DB_DRIVER` 选择后端，不含存储语义。
- MySQL 驱动要点：`entity_partition.payload` 存 fid→value 的 JSON、`entity_field` 只写 `persist=index` 字段；`save` 用单事务做脏分区 upsert + `entity.rev` 更新 + 索引 upsert；init 从 6 张表重建内存热缓存。
- `test/test_mysql_roundtrip.lua`（35 断言）：同套 CRUD 契约 + 索引/blob 分离落库 + **重启模拟**（新建驱动实例从 MySQL 重建缓存，gold 值不变）。
- `runtime.lua` / `conf/skynet.conf` / `main.lua` / `Makefile` 增加 `CH13_DB_*` 配置与 `make test-mysql` 目标。

**环境（已就绪，2026-11-21 实测）**：
- WSL Ubuntu 26.04.1 已安装 `mysql-server/client 8.4.13`，监听 `127.0.0.1:3306`；`/etc/wsl.conf` 启用 systemd，mysql 服务 `enabled`，重启自动拉起。
- `libmysqlclient-dev 8.4.13` 已安装（C 扩展编译依赖）。
- 开发者账号：`dev` / `dev123`；项目库：`ch13_palace`（utf8mb4）。

**验收（实测）**：
```
make -C ch13_palace test-mysql
CH13_DB_DRIVER=mysql make -C ch13_palace test-one T=test_gate
```
结果：`=== TOTAL: 35 PASS, 0 FAIL ===`（MySQL 往返）；`=== TOTAL: 41 PASS, 0 FAIL ===`（MySQL 驱动下网关端到端，库内真实写入 1 账号 / 5 分区）；默认内存全量 `129 PASS, 0 FAIL` 不回归。rc 均为 0。

**人日**：3~4（不含环境安装，已投入）。

---

## 阶段 3：会话完整化（断线、重连、顶号、回写）（已完成）

**目标**：跑通原链路里真正影响体验的部分。

**交付**：
- `conf/schema.xlsx` 的 `actions` 表给 `u.login` 增加第三位 `token`（走导表纪律：改 Excel → `make gen`，不手改生成物）；token 仅用于**精确找回挂起会话**，鉴权仍走账号密码，兼容老客户端只传两位参数的调用。
- `service/agent.lua` 由 `afk` 占位升级为四个会话命令：`suspend()` 标记挂起、`resume(fd)` 恢复并返回快照、`expire()` 调 `db.save(uid)` 返回写入分区清单、`shutdown()` 退出。
- `service/gated.lua` 升级为**会话状态机**（全部状态在本服务内，skynet 单服务串行天然无锁）：
  - `session_by_uid` / `session_by_token` 双索引；会话含 `state`(`active`/`suspended`)、`fd`、`gen` 字段。
  - 断线不销毁 agent：挂起 + `skynet.timeout(grace)` 开重连窗口。
  - `gen` 递增使旧定时器失效：重连/顶号后旧 grace 回调自然 return，无竞态。
  - 顶号：先给旧 fd 发 `u.error` 通知帧，再摘除其连接并关闭；旧连接的 `disconnect` 因 `s.fd` 已指向新连接而不误伤新会话。
  - 超时：`agent.expire()` 落盘 → 记入 `expire_log` → `session_by_*` 清除 → `shutdown`。
  - 管理命令：`session_stats` / `session_of` / `set_grace` / `reset_sessions` / `last_expire`。
- `runtime.lua` / `conf/skynet.conf` / `main.lua` 增加 `session_grace`（默认 300 ticks=3s，`CH13_SESSION_GRACE` 可覆盖）；`main.lua` 把它传给网关 init。
- `test/test_reconnect.lua`（46 断言）：T1 断线挂起、T2 带 token 换 fd 恢复、T3 超时落盘+重建登录、T4 顶号。
- 默认 `TARGET` 纳入 `test_reconnect`。

**验收（实测）**：
```
make -C ch13_palace test-one T=test_reconnect        # 46 PASS, 0 FAIL
make -C ch13_palace test                              # 175 PASS, 0 FAIL（全量不回归）
CH13_DB_DRIVER=mysql make -C ch13_palace test-one T=test_reconnect
                                                      # 46 PASS, 0 FAIL
```
MySQL 驱动下库内实证：`entity_partition` 写入 `hero={"6":{"rc-h1":3}}`、超时落盘与顶号后动作均真实落库；内存与 MySQL 两种驱动下会话语义一致。rc 均为 0。

**修复记录**：首版 T4 断言用客户端 socket fd 比较网关侧 fd——二者是不同服务里的独立句柄，数值无关联；改为网关侧 `takeover` 计数器作为顶号的确定性证据。

**人日**：3~4（已投入）。

---

## 阶段 4：快照分区订阅与 wire 级增量（服务端已完成）

**目标**：拿到网络省流量收益（**客户端改造是独立前置条件**，服务端已备好开关与参考实现）。

**交付**：
- `conf/schema.xlsx` 的 `actions` 表追加 4 个 wire 动作（aid=6 u.snapshot / 7 u.delta / 8 u.subscribe / 9 u.unsubscribe，aid 只追加不复用）；`tools/gen_schema.py` handler 白名单增加 `wire`。
- **capability 协商做在信封层**：首包顶层带 `wire=2` 才启用新协议；老客户端不带 → 默认 `wire=1` 全量快照 + delta 嵌回包，**现有客户端零改动**。`agent.set_wire(v)` 在鉴权后设置。
- `shared/schema.lua` 新增 `snapshot_by_policy(state, subscribed)` 与 `delta_allowed(fid, subscribed)`：`snapshot`/`delta` 字段默认下发、`on_demand` 仅订阅后下发、`none` 永不下发；空分区不输出。
- `service/agent.lua` 的 `handle_wire` 处理 4 个新动作：订阅/退订维护订阅集；主动拉快照（可指定分区）；按 `base_rev` 追帧生成合并增量（只含允许下发的 fid）。`CMD.snapshot()` 按 wire 版本选择全量或策略过滤。
- `service/gated.lua`：wire=2 时 delta 从回包 `params.delta` 改为独立 `u.delta` 推送帧；wire=1 保持嵌入式（兼容）。
- `shared/client_state.lua`：**给客户端团队移植的参考实现**——`apply_snapshot` 展开分区、`apply_delta` 做严格 `base_rev` 校验（重复/过期拒绝）与 mask/values 应用。原工程协议无版本号，这一步必须客户端改。
- `test/test_delta_wire.lua`（54 断言）：T1 legacy 全量兼容 / T2 策略过滤 / T3 订阅可见性与退订 / T4 独立 delta 包与客户端应用 / T5 base_rev 校验与追帧 / T6 消息压缩对比。

**验收（实测）**：
```
make -C ch13_palace test-one T=test_delta_wire   # 54 PASS, 0 FAIL
make -C ch13_palace test                          # 229 PASS, 0 FAIL（全量不回归）
CH13_DB_DRIVER=mysql make -C ch13_palace test-one T=test_delta_wire
                                                  # 54 PASS, 0 FAIL
```
rc 均为 0，schema check：`12 fields, 9 actions, 7 errors, xlsx in sync`。MySQL 下两种 wire 数据均正确落库（v2 账号 mission 分区含 `{"8":{"daily":2}}`）。

**修复记录**：三个测试假设错误——新角色只有 base 分区有初始值，hero/item 为空（策略过滤刻意不下发空分区）；订阅前需先注入任务数据才有内容可见；注入数据使服务端 rev 前进，客户端动作前需重新同步快照。均属测试侧修正，实现未改。

**客户端待办（不阻塞服务端验收）**：客户端团队把 `shared/client_state.lua` 的逻辑移植到 Unity 侧，首包带 `wire=2`，处理独立 `u.delta` 包与订阅动作。未移植前保持 `wire=1` 即可零改动运行。

**人日**：服务端 5~7（已投入）；客户端改造另估。

---

## 阶段 5：动作批量迁移与双跑对账（已完成前三批）

**目标**：把原工程 528 个 `@Rpc` handler 按玩法逐批迁入，每批可回滚、可对账。

**已落地的基础设施**（本阶段新增，后续批次直接复用）：

1. **处理器注册制**：`service/handler/<domain>.lua`，schema 的 `handler` 列决定路由，
   `agent.lua` 只做 `pcall(require)` 缓存与 ctx 注入，不再有 `if handler ==` 分支。
   handler 契约：`M.handle(ctx, action, params) -> { err, result, changes }`；
   ctx 提供 `get/set_fields/rev`，业务不直接碰 state 与 db。
2. **游戏内容配表**：`conf/gamedata.xlsx`（hero / hero_exp / hero_surmount / hero_week / item / mission），
   `tools/gen_gamedata.py` 生成 `generated/gamedata_generated.lua` + JSON 镜像，
   `shared/gamedata.lua` 是唯一访问层。数值不再散落在 handler 里。
3. **对账工具**：`service/replay.lua`（离线回放）+ `tools/compare_with_java.py`（比对）。
   样本在 `docs/samples/<batch>.json`，每个 case 带 `source`（Java 文件:行号）与 `derivation`（期望值怎么算出来的）。
   比对语义：`err` 全等、`result` 子集、`state` 点路径（`null` 表示该键应缺失）。

**已迁移批次**：

| 批次 | 动作 | 原工程出处 | 测试 | 对账 |
|---|---|---|---|---|
| hero | `u.heroUpdateLvAuto` / `u.heroUpdateAdvanceLv` / `u.heroUpdateLimitLv` | HeroService:865 / 1311 / 1384 | `test_action_hero` | 11 cases |
| item | `u.useItem` / `u.itemSale` | UserProxy:701 / ItemService:1070 | `test_action_item` | 6 cases |
| mission | `u.missionClaimReward` | MissionProxy:37 / MissionService:82 | `test_action_mission` | 6 cases |

另有 2 个 `u.dev.*` 脚手架动作（造数用，非原工程 op，不计入迁移数量）。

**每批的固定动作**（后续批次照此执行）：
1. `conf/schema.xlsx` 的 actions 追加条目（aid 只增不复用），`make gen` 导表。
2. 新增 `service/handler/<domain>.lua`，实现 `M.handle`；数值一律查 `shared/gamedata.lua`。
3. 新增 `test/test_action_<domain>.lua`，断言规则本身（上限、消耗、失败分支、rev 前进一次）。
4. 新增 `docs/samples/<domain>.json`，每条 case 标注 Java 出处与推导；跑 `make reconcile`。
5. 难度顺序建议：英雄养成已完成 → 背包/道具已完成 → 任务已完成 → 活动 → 社交 → 跨服（依赖 Redis，最后）。

**验收**：
```
make -C ch13_palace verify          # test + reconcile 全过
make -C ch13_palace reconcile-mysql # 同一批样本在 MySQL 驱动下重跑
```
通过标准：`test` 0 FAIL；`RECONCILE: N cases, 0 failed`；两种驱动结果一致。

**当前实测**：`make test` 327 PASS / 0 FAIL；`make reconcile` 23 cases / 0 failed；
`make reconcile-mysql` 23 cases / 0 failed。

**人日**：基础设施（注册制 + gamedata 管道 + 对账工具）约 4；每批 1~2；剩余全量 20~30。

---

## 阶段 6：灰度与上线（可选）

1. 网关加灰度开关：按账号哈希把 1% → 10% → 100% 流量切到新栈。
2. 保留一键回滚：老栈进程常驻，gate 按开关路由。
3. 监控：登录成功率、P99、delta 拒绝率、脏分区写行数。
4. 压测：1000 并发登录，指标对齐 ch4_login 的基线方法（不承诺具体数值）。

**人日**：8~12。

---

## 总览

| 阶段 | 人日 | 前置依赖 | 可独立验收 |
|---|---:|---|---|
| 0 契约基座 | 2~3 | 无 | 是（已完成） |
| 1 TCP 网关 | 3~4 | 0 | 是（已完成） |
| 2 MySQL 驱动 | 3~4 | 0 | 是（已完成） |
| 3 会话完整化 | 3~4 | 1 | 是（已完成） |
| 4 wire 增量 | 5~7 | 3 + 客户端 | 是（服务端已完成） |
| 5 动作迁移 | 20~30 | 1,2,3 | 按批次（前三批已完成） |
| 6 灰度上线 | 8~12 | 5 | 是 |

**关键路径**：阶段 1、2、3、4 服务端（均已完成）→ 5（进行中，已迁 3 批 / 共 528 个 handler）。
**已证伪点**：阶段 0 证明「生成代码可替代手写 VO」成立；阶段 1 证明「现有客户端帧格式可零改动接入统一消息链路」成立；阶段 2 证明「抽象存储可在上层零改动下换后端」成立；阶段 3 证明「会话状态机在单服务串行下可无锁实现断线/重连/顶号/超时落盘」成立；阶段 4 证明「信封级 capability 协商可同时承载 legacy 全量协议与 wire2 策略过滤/订阅/独立增量」成立；阶段 5 前三批证明「按领域注册 handler + Excel 内容表 + 回放对账」的批次流水线可重复，且换存储驱动不改语义。
**剩余前置**：阶段 4 的省流量收益需客户端移植 `client_state.lua` 并带 `wire=2` 才能兑现；未移植时 wire=1 零改动运行。
