# ch13_palace 整体架构设计

> 目标：以**抽象数据 + 抽象消息**为主体，用最少的数据库表记录所有数据，用最少的消息种类定义整个工程所有消息；
> 语义（含义、路由、类型、持久化策略）全部外置到配置，配置作为单一事实源生成代码。
>
> 范围：先还原「test 渠道登录 → 加载/创建角色 → 推初始快照 → 动作变更 → 断线回写」这条关键链路。
> 战斗、聊天、跨服、支付、GM、284 张配表均不在本工程范围内。

---

## 1. 设计边界（最重要的一节）

抽象的是**载体**，不是**行为**。

| 层 | 做法 | 理由 |
|---|---|---|
| 存储 | 抽象：实体只存 fid，含义由 schema 赋予 | 字段增删不改表结构，写放大可控 |
| 状态复制 | 抽象：`SNAPSHOT` + `DELTA` 两种信封 | 登录包不再逐字段堆消息 |
| 动作 | 抽象信封与参数 schema，不抽象 handler 逻辑 | 抽卡/战斗是多步事务，配置无法描述顺序敏感行为 |
| 渠道/支付/GM | 保持具体 | 外部 SDK 与对账语义不可抽象 |

配置能描述「这个字段叫什么、是什么类型、属于哪个分区、要不要落库、怎么复制」；
配置**不能**描述「抽卡先扣钱还是先随机、失败怎么回滚」。后者留在代码里。

---

## 2. 服务拓扑

```
   TCP 客户端 │ 2字节长度 + legacy JSON + 4字节session
                                │
                       ┌────────▼────────┐
                       │ gated (snax)    │  首包鉴权 / fd↔agent / 帧编解码
                       └────────┬────────┘
                                │ 归一化（op → aid，位置参数 → 命名参数）
                       ┌────────▼────────┐
                       │ shared/message  │  7 种统一信封
                       └────────┬────────┘
                    ┌───────────┼────────────┐
              ┌─────▼─────┐ ┌───▼────┐ ┌─────▼─────┐
              │ login     │ │ agent  │ │ db        │
              │ 账号/session│ │ 会话/动作│ │ 分区/脏写  │
              └─────┬─────┘ └───┬────┘ └─────┬─────┘
                    └───────────┼────────────┘
                       ┌────────▼────────┐
                       │ conf/schema.xlsx│  单一事实源
                       │ + 生成物         │
                       └─────────────────┘
```

- `main.lua`：启动 db、login、gated 并开放端口，按 `CH13_TEST_TARGET` 拉起测试服务并汇总退出码。
- `service/gated.lua`（阶段 1~3）：基于 `snax.gateserver + netpack` 的 TCP 网关 + 会话状态机。首包鉴权、fd ↔ agent 映射、帧编解码、未知 op 拒绝；阶段 3 增加连接挂起/恢复/顶号/超时落盘，全部状态在本服务内串行处理。
- `service/db.lua`：唯一持有持久化状态的服务。实体分区、rev、脏标记、JSON 快照。
- `service/login.lua`：test 渠道（sdkId=0）账号创建与 md5 校验、session token。
- `service/agent.lua`：一个玩家一个服务实例，绑定 uid，处理 `ACTION_REQ`，产出 delta；阶段 3 增加 `suspend/resume/expire/shutdown`，断线后按 grace 窗口等待重连，超时落盘退出。
- `shared/message.lua`：协议归一化与信封，7 种 kind。
- `shared/schema.lua`：schema 访问层，禁止业务直接写 `state[数字 fid]`。
- `test/gateclient.lua`：测试用阻塞 TCP 客户端，与网关共用帧格式。

---

## 3. Schema Registry

单一事实源：**`conf/schema.xlsx`**（Excel 工作簿，4 个 sheet：fields / actions / errors / meta）。
由 `tools/gen_schema.py` 经零依赖 OOXML 解析生成 Lua；`conf/schema.json` 仅为可读镜像，不参与运行。
完整设计与命令见 `tools/XLSX_PIPELINE.md`。

生成物：

- `generated/fields_generated.lua`：fid ↔ name、分区字段表、索引字段
- `generated/actions_generated.lua`：aid ↔ 老 op、参数名、handler 名
- `generated/errors_generated.lua`：错误码

`tools/check_schema.py` 校验 Excel 与生成物是否同步，`make test` 强制先跑校验。
编辑入口是 Excel，不是生成物或 JSON 镜像。

规则（不可违反）：

1. **fid 永不复用、类型只扩不改**；删除字段用 `deprecated` 标记，不物理删除。
2. aid 一旦发布不可换 op；新增 action 只追加。
3. `persist` 取值：`index`（提升为索引列）/ `blob`（随分区写）/ `lazy`（按玩法加载）/ `derived`（运行时算，不入库）/ `transient`（不入库）。
4. `replicate` 取值：`snapshot`（登录快照）/ `delta`（增量）/ `on_demand`（订阅才推）/ `none`。
5. 业务代码只能通过 `schema.get/set` 访问字段，保证「数据无意义、配置赋义」。

当前规模：12 字段 / 5 action / 5 分区（base、hero、item、mission、activity）。

---

## 4. 数据存储设计

### 4.1 最小表集（目标形态，MySQL 阶段）

| 表 | 关键列 | 用途 |
|---|---|---|
| `account` | uid, name, salt, pwd_hash, sdk_id, status | 登录热路径，保留类型化列 |
| `entity` | uid, etype, owner, rev, updated_at | 实体索引 |
| `entity_partition` | uid, partition, rev, payload, crc | 分区 blob，只写脏分区 |
| `entity_field` | uid, fid, value | 仅 `persist=index` 的查询字段 |
| `event_log` | seq, uid, aid, ts, actor | 审计与问题回放 |
| `leaderboard_projection` | rank_key, uid, score | 派生投影，非真相源 |

相比原工程「AvatarModel 99 列 + 11 子表全删全插 + 15 日志表」，核心价值是：
- 加字段不改表结构；
- 只写脏分区，避免 6 个 6.25MB 大列每 300 秒全量重写；
- 索引列与 blob 分离，查询不受 EAV 退化影响。

### 4.2 落地形态：双驱动，同一契约

`service/db.lua` 是驱动分发的薄层，按 `CH13_DB_DRIVER` 选 `memory` / `mysql`；两个驱动实现**完全相同的方法契约**，
上层（login / gated / agent）零改动：

- **memory 驱动**（阶段 0，对照基线）：内存表 + JSON 快照；`CMD.set_fields` 按 schema 找分区、标脏、rev+1；`flush` 写 JSON，fid 数字键经往返保持为数字。
- **mysql 驱动**（阶段 2）：
  - `clib/mysql.c` 同步 MySQL C 扩展，产物 `clib/mysql.so`（未改 skynet 子模块，经 `lua_cpath` 加载）；db 服务是串行单点，同步调用不引入并发冲突。
  - `conf/ddl.sql` 建 6 张表；init 时从表重建内存热缓存，`load()` 仍返回带 `__rev` 的 state。
  - `entity_partition.payload` 存 fid→value 的 JSON（blob/lazy 字段），`entity_field` 只写 `persist=index` 字段（uid/account/level/gold）。
  - `save(uid)` 用单事务：脏分区 upsert + `entity.rev` 更新 + 索引字段 upsert，并记一条 `event_log`。
  - 幂等：DDL `CREATE TABLE IF NOT EXISTS`（`partition` 为保留字需反引号）；测试 `reset` 清表可重跑。

**实证**：MySQL 驱动下网关端到端 41 PASS 全过且库内真实写入 1 账号 / 5 分区；重启模拟（新驱动实例从 MySQL 重建缓存）gold=500 保留。上层零改动换后端成立。

---

## 5. 消息契约

### 5.1 统一信封（7 种）

| kind | 名称 | 用途 |
|---:|---|---|
| 1 | `HELLO` | 鉴权/握手 |
| 2 | `ACTION_REQ` | `{seq, aid, params}`，参数按 schema 命名 |
| 3 | `ACTION_RES` | `{seq, aid, err, result, delta}` |
| 4 | `SNAPSHOT` | `{rev, partitions}`，登录初始包，一条替代 16 条 |
| 5 | `DELTA` | `{base_rev, rev, mask, values}`，mask 为排序后的 fid 列表 |
| 6 | `EVENT` | 服务端主动推送 |
| 7 | `PING` | 低频校时，取消每秒全服广播 |

### 5.2 兼容策略

- 入站：`normalize_in({op="u.xxx", params={...}})` 查 schema 得 aid，位置参数按 `action.params` 变成命名参数。
- 出站：`to_legacy()` 把统一信封转回老协议 `{id,type,scope,op,error,params}`。
- 因此**现有客户端零改动即可接入内部统一消息链路**，但 wire 级省流量收益需客户端配合。
- 阶段 1 的 DELTA 不单独发 `u.delta` 包，而是嵌在 ActionRes 的 `params.delta` 里；独立包留到阶段 4。
- 增量应用：客户端拿 `base_rev` 校验，`state.__rev >= delta.rev` 视为重复/过期并拒绝。
- 帧格式：`2 字节大端长度(不含自身) + JSON + 4 字节大端 session`，与 `ch4_login/gateway/gated.lua` 一致。
- 首包只接受 `u.login`(aid=1) / `u.create`(aid=2)；非法首包回 `UNKNOWN_OP(-100)` 后关闭连接。
- `u.login` 的 params 第三位是 `token`（schema 配置，老客户端只传两位仍兼容）；token 用于精确找回挂起会话，鉴权仍走账号密码。
- 未知 op 在已登录连接上回 `-100` 但不关连接；粘包由 `netpack` 拆帧，网关按帧逐个处理。

### 5.4 会话状态机（阶段 3）

```
     首包鉴权 ──→ [active] ──断线──→ [suspended] ──grace 内 token/u.login──→ [active]
                    │                     │
                    │ 同 uid 新登录        │ grace 到期
                    ↓                     ↓
                 顶号：旧 fd 摘除     expire() → db.save(uid) → 清索引 → shutdown
                    │                     │
                    └────→ agent 复用 ←────┴──→ 新登录则新建 agent
```

- 三张索引都在 `gated` 单服务内：`connection[fd]`、`session_by_uid[uid]`、`session_by_token[token]`；无锁由 skynet 消息串行保证。
- `gen` 递增版本号使旧 grace 回调失效：重连/顶号后旧定时器触发时发现 `gen` 不匹配直接返回，无需 cancel timer。
- 顶号先给旧 fd 发一帧 `u.error(BAD_STATE)` 再摘除连接；旧连接随后的 `disconnect` 因 `session.fd` 已指向新 fd 而不会误挂起新会话。
- 超时落盘调 `agent.expire()` → `db.save(uid)`（只写脏分区）→ 写入清单记入 `expire_log`，供审计与测试断言。
- grace 窗口默认 3 秒（`session_grace`，单位 0.01s），可经 `CH13_SESSION_GRACE` 覆盖；测试内用管理命令 `set_grace` 缩到 0.3s。

### 5.5 wire 协议分级与分区订阅（阶段 4）

**Capability 协商在信封层**：首包顶层 `wire` 字段（老客户端不发送）：

| wire | 快照 | 增量 | 订阅 | 适用 |
|---|---|---|---|---|
| 1（默认/legacy） | 5 分区全量（含空分区与 `none` 字段） | 嵌在回包 `params.delta` | 无 | 现有客户端零改动 |
| 2（新协议） | 按 `replicate` 策略过滤，空分区不下发 | 独立 `u.delta` 推送帧 | `u.subscribe`/`u.unsubscribe` | 客户端移植 `client_state.lua` 后 |

**字段级策略**（来自 Excel `fields.replicate`）：`snapshot`/`delta` 默认下发；`on_demand` 仅该分区订阅后下发；`none` 永不下发。`schema.snapshot_by_policy()` 与 `schema.delta_allowed()` 是唯一判定点，业务不写死字段。

**wire 动作**（Excel `actions` 追加，aid 不复用）：
- `u.snapshot(partitions)`：主动拉快照，空参数则按策略；指定分区则按名取。
- `u.delta(base_rev)`：落后 rev 追帧，返回合并增量（只含允许下发的 fid）。
- `u.subscribe(partitions)` / `u.unsubscribe(partitions)`：订阅集存于 agent 会话，断线挂起期间保留。

**客户端参考实现**：`shared/client_state.lua` 的 `apply_snapshot` / `apply_delta` 是给客户端团队移植的样板——严格 `base_rev` 相等校验（重复/过期拒绝），再按 `mask` 应用 `values`。原工程协议无版本号，这一步必须客户端配合；未移植前 wire=1 全量模式可零改动运行。

### 5.3 关键流程

**登录**：`legacy u.login`（可带顶层 `wire=2`）→ `ACTION_REQ(aid=1)` → `login.auth` 校验 `md5(客户端32位md5 + salt)` → token → `set_wire` → 创建/加载实体 → `SNAPSHOT`（legacy 一条全量 / wire2 一条按策略过滤）→ 客户端消费。

**动作**：`legacy u.heroUpdateLv` → `ACTION_REQ(aid=3)` → agent 查 schema 得 handler=hero → 改字段、标脏、rev+1 → `ACTION_RES`；DELTA 在 wire=1 嵌回包、wire=2 独立成 `u.delta` 帧 → 客户端 `apply_delta` 按 `base_rev` 校验后应用。

---

## 6. 动作层：处理器注册制与批次迁移（阶段 5）

### 6.1 为什么不再用 if 链

`agent.lua` 早期用 `if action.handler == "hero" ... elseif ...` 分派，只能承载 3 个玩具动作，
无法承载 528 个 handler 的分批迁移。现在改为**按领域注册**：

```
schema.actions[aid].handler  ->  require("handler." .. name)  ->  M.handle(ctx, action, params)
```

- `agent.lua` 只负责：查 schema、`pcall(require)` 缓存、构造 ctx、统一打 delta、错误码兜底。
- 新增一批动作 = 新增一个 `service/handler/<domain>.lua` + 导表加 action 行，不动 `agent.lua`。
- handler 契约：`{ err, result, changes }`；`changes` 是字段名 → 新值，由 agent 统一 `set_fields` + 生成 delta。
- ctx 只暴露 `get(name)` / `set_fields(changes)` / `rev`，handler 不能直接改 state 或调 db。

### 6.2 内容配置与抽象数据的边界

`conf/schema.xlsx` 定义**载体**（fid 含义、分区、持久化、复制策略），
`conf/gamedata.xlsx` 定义**内容**（英雄模板、经验曲线、加官/进爵消耗、道具效果、任务奖励）。

两者都走 Excel → Lua 的零依赖管道，都在 `make gen` 里校验同步。
handler 不硬编码任何数值：`gd.hero_need_exp(lv,toLv)`、`gd.surmount(tpl,adv)`、`gd.item(id)` 是唯一入口。

这样做的收益：调数值是改表不是改代码；同一套规则能被测试、对账样本和线上共用一份事实源。
代价：配置错误会直接改变线上行为，因此 `check-gamedata` 是 `make test` 的前置门禁。

### 6.3 双跑对账（批次门禁）

```
docs/samples/<batch>.json  ──►  service/replay.lua  ──►  /tmp/ch13_replay_*.json
        (seed/op/params/expect)         (干净实体逐条回放)              │
                                                                        ▼
                                            tools/compare_with_java.py  ──►  差异表 + 退出码
```

- 样本每条 case 带 `source`（原工程 Java 文件:行号）和 `derivation`（期望值的手算过程），
  这是「对账」而不是「自证」的关键：期望值先于实现写下来。
- 比对语义刻意宽松：`err` 全等、`result` 只比期望里出现的键、`state` 用点路径点名，
  `null` 表示该键应缺失。避免把无关字段的变化误报成回归。
- 同一批样本必须在 memory 与 mysql 两种驱动下都通过——否则说明持久化层改变了语义。
- 门禁：`make verify` = `test` + `reconcile`；任一失败不允许进入下一批。

### 6.4 已迁移批次

| 批次 | 动作数 | 规则要点 | 测试断言 | 对账样本 |
|---|---:|---|---:|---:|
| hero | 3 | 三重等级上限、经验丹贪心吞、溢出经验保留、加官/进爵门槛 | 41 | 11 |
| item | 2 | 货币类道具转货币、经验丹不可直用、先判库存再判可售 | 27 | 6 |
| mission | 1 | 记录不存在→已领取→未完成→发奖置 claimed | 21 | 6 |

另有 `dev` 处理器（2 个 `u.dev.*` 造数动作），不属于原工程，不计入迁移数量。

---

## 7. 已知取舍与风险

- **配置即代码**：schema 变更必须与代码同流程 review/灰度/回滚；fid 写错会导致全服数据解释错位。
- **查询**：排行榜/公会/邮件必须走投影或内存索引，不能遍历 `entity_field`；原工程 `SharedEntity` 内存索引可作为投影层原型。
- **工具链**：GM/客服/BI 依赖具体列名，抽象后必须提供 schema-aware 查询界面。
- **热更**：Lua 配置可热更，但涉及落盘 schema 的变更必须双写 + 迁移脚本。
- **不在范围内**：战斗确定性、跨服、支付对账、284 张配表迁移。

---

## 8. 当前实现状态

`make test` 实测 **327 PASS / 0 FAIL**（10 个测试服务：schema、storage、message、login_flow、gate、reconnect、
delta_wire、action_hero、action_item、action_mission，默认 memory 驱动）。
`make test-mysql` 实测 **35 PASS / 0 FAIL**（MySQL 往返 + 重启持久化）。
`make reconcile` 实测 **23 cases / 0 failed**；`make reconcile-mysql` 同样 **23 / 0**（换驱动不改语义）。

已实现：schema 生成与校验、分区脏写与 rev、统一信封与归一化、test 渠道登录、动作 delta、快照往返、
TCP 网关（legacy 帧收发、首包鉴权、实体复用、粘包、在线计数）、双存储驱动（memory / mysql）、
会话完整化（断线挂起、token/账号找回重连、顶号、grace 超时落盘退出）、
wire 分级协议（信封 capability 协商、replicate 策略过滤、分区订阅、独立 u.delta、base_rev 追帧、客户端参考实现）、
处理器注册制与内容配表（hero/item/mission 三批共 6 个动作 + 2 个 dev 造数动作）、离线回放对账工具。

未实现：其余 522 个原工程 handler、客户端移植（Unity 侧 `client_state` + wire=2 开关）、灰度开关。
