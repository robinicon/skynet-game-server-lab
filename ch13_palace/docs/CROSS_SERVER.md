# 跨服机制分析与优化设计

> 审计对象：`C:\workspaces\palaceserver\trunk`（Java 原服，只读）
> 落地对象：`C:\workspaces\bookskynet\ch13_palace`（skynet 版）
> 性质：**机制分析 + 优化设计 + 最小可运行方案**。本文不含已落地代码。
> 落地上限（已确认）：**只做最小可运行骨架，不做完整跨服战/世界 Boss/公会战。**

---

## 0. 一页结论

原服的跨服不是"一个功能"，而是**一套跨进程基础设施**：`global` 中心进程做控制面、Redis 做数据面、`fight` 独立进程做战斗面，三者通过 7 个 `co.*`（中心回调 GAS）+ 46 个 `gl.*/gld.*`（GAS 调中心 39 个、中心调 DB 7 个）串起来。跨服排行、跨服战、跨服邮件/喇叭、跨服师徒、邀请码全部挂在这套设施上。

**做对的三件事**（值得带到新版）：
1. **控制面与数据面分离**——中心只管编排与合并，重数据（战报、玩家快照）放 Redis/DB，不挤中心内存。
2. **懒加载回源**——`getFightSide` 取不到才 `syncOppInfo` 回源，稳态不预拉。
3. **结算与回放分离**——`FightEngine` 算结果，`VSRecordModel` 存战报，回放走独立读路径。

**五个真问题**：
1. **中心轮询全量**：每 5 分钟向所有 GAS 广播 `co.syncGlobalRank`，各服回推 top-200，中心 `synchronized` 合并全量重排。服数上去后是 O(服数 × 200) 的定时突刺，且排行新鲜度恒为"上一轮"。
2. **中心纯内存**：`CACHE_GLOBAL_RANK_MAP` 不掉盘，global 重启后排行清空，需等一个轮询周期重建。
3. **跨服战阻塞回源无超时**：`syncOppInfo` 同步等对端，对端已下线时调用悬挂。
4. **单开关 `OPEN_CROSS`**：全局一刀切，无法按分组/按特性/按比例灰度。
5. **`cross$group$sid` 字符串做路由**：格式校验靠 `split`，玩家 ID 拼接后不可逆解析。

**新版方案一句话**：用 **skynet 内的 `hub` 单服务**替代"global 进程 + Redis + 独立 fight 进程"，排行从"中心全量轮询"改成"**增量推送 + 版本号 + 按需对齐**"（稳态零轮询），跨服战从"同步阻塞取数据"改成"**两阶段 + TTL + 超时不阻塞**"，开关改成"**分组 / 特性 / 比例**三级"。

**本次落地**：`service/hub.lua` + 2 个动作（`u.crossRank` / `u.crossSubmit`）+ 4 条断言。跨服战只留 schema 注释与接口签名，不实现。

---

## 1. 原服机制（事实）

### 1.1 三层拓扑

```
              ┌──────────────────────────────┐
              │  palace-global (9008/9009)   │  控制面：编排、合并、转发
              │  GlobalAppProxy  @Rpc gl.*   │  3,541 行
              │  GlobalRankService  116 行   │
              └───────┬──────────────┬───────┘
        GlobalClient  │              │  Jedis
        (长连, RPC)   │              │
   ┌──────────────────┴───┐   ┌──────┴───────────────┐
   │  GAS (9101) × N 服   │   │  Redis               │  数据面：跨服共享
   │  CrossServerListener │   │  zset 排行            │
   │  @Rpc co.*  (7 个)   │   │  hash FightSide      │
   └──────────┬───────────┘   │  hash GlobalAvatar   │
              │ FightClient    └──────────────────────┘
   ┌──────────┴───────────┐
   │  fight (9018) 独立   │  战斗面：结算、战报
   │  FightEngine         │  102 文件 / 13,384 行
   └──────────────────────┘
```

`CrossServer.java`（79 行）只做一件事：把 Spring 里所有 `@AutoCrossListener` 的 bean 注册到 `GlobalClient`，再 `connect()`。`initfight()` 同理注册到 `FightClient`。**注册是注解驱动的，加一个跨服能力不用改这个类。**

### 1.2 协议面

| 前缀 | 方向 | 数量 | 例子 |
|---|---|---:|---|
| `co.*` | 中心 → GAS（call other） | **7** | `co.syncGlobalRank` / `co.sendMail` / `co.sendGlobalEmailReward` / `co.sendGlobalEmailupAndDown` / `co.sendGlobalnotifyMessage` / `co.saveGlobalavatarInfo` / `co.test` |
| `gl.*` | GAS → 中心 | **39** | `gl.syncPersonInfo` / `gl.getAvatarInfo` / `gl.doFightGlobal` / `gl.saveGlobalFightContext` / `gl.fightPlayback` / `gl.shitu.*`（21 个师徒）/ `gl.invite.*`（7 个邀请码） |
| `gld.*` | 中心 → 中心 DB | **7** | `gld.invitation.getInviter` / `inviterGenCode` / `inviteeFillCode` 等 |

**46 个 GAS→中心常量（39 + 7）的分布，说明"跨服"在原服是一个共享中心被多种玩法复用**：

| 用途 | 个数 | 占比 |
|---|---:|---:|
| 师徒 `gl.shitu.*` | 21 | 46% |
| 邀请码 `gl.invite.*` + `gld.invitation.*` | 14 | 30% |
| 跨服战 `gl.doFightGlobal` / `saveGlobalFightContext` / `fightPlayback` / `fightPlaybacklist` | 4 | 9% |
| 排行 `gl.syncGlobalRank` / `gl.getGlobalRank` | 2 | 4% |
| 玩家数据 `gl.syncPersonInfo` / `gl.getAvatarInfo` | 2 | 4% |
| 喇叭 / 邮件 / test | 3 | 7% |

**跨服排行只占 4%，跨服战只占 9%。** 所以新版必须把跨服做成**通用设施**（`hub`），而不是给排行写死一条链路——否则将来接跨服战、跨服邮件时要推翻重做。

### 1.3 跨服排行时序（核心问题所在）

```java
// GlobalRankService.startSyncRankListTimer —— 中心侧，每 5 分钟
for (ServerInfo s : globalManager.getServerInfoManager().getServerInfoMap().values())
    globalManager.callServer(s.getIdentify(), CALL_SYNC_GLOBAL_RANK, new Object());
```

```java
// 各服回调 —— 把自己的 top-200 全量推上去
public void syncGlobalRank() { rankService.synchronizeGlobalRank(); }
```

```java
// 中心合并 —— synchronized 大锁 + 全量 HashSet 去重 + 全量排序
synchronized (CACHE_GLOBAL_RANK_MAP) {
    Set<RankGlobalInfo> sets = new HashSet<>(rankInfos);   // 本次上报
    sets.addAll(rankList);                                 // 上次结果
    List<RankGlobalInfo> tempList = new ArrayList<>(sets);
    tempList.sort(null);                                   // 全量排序
    ... subList(0, 200) ...
    CACHE_GLOBAL_RANK_MAP.put(rankKey, list);
}
```

参数：`RANK_REFRESH_GAP = 5 分钟`、`GLOBAL_RANK_LEN = 200`。

**五个可指出的点**：

| # | 现象 | 后果 |
|---|---|---|
| 1 | 中心定时向**所有**服广播 | 广播量 = 服数；每服回推 200 条 → 单轮 N×200 条 JSON |
| 2 | 每次**全量**去重 + 全量排序 | O(N×200·log) 且持锁；合并期间 `getGlobalRank` 阻塞 |
| 3 | 排行新鲜度 = `RANK_REFRESH_GAP` | 玩家刚打的分数最多 5 分钟后才上榜 |
| 4 | `CACHE_GLOBAL_RANK_MAP` 纯内存 | global 重启 → 排行清空 → 冷启动空窗一个周期 |
| 5 | 无版本无幂等 | 重复/乱序上报按"最后到达"覆盖，无法判断新旧 |

### 1.4 跨服战时序

```java
// 入口：GAS 把双方 key 传给中心
@Rpc(fullAlias = GlobalServerRpcConstants.DO_FIGHT_GLOBAL)
public void dofightGlobal(RpcResult r, String myKey, String otherKey) { ... }

// 中心：从 Redis 取两侧 FightSide
FightSide myside  = globalAppJedisService.getFightSide(myKey);
FightSide oppside = globalAppJedisService.getFightSide(opkey);
if (myside == null || oppside == null) {
    if (syncOppInfo(opkey, rpcResult)) return;   // ← 同步回源，无超时
    rpcResult.result(null);
}
FightEngine.getInstance().startFight(fightContext, rpcResult);
```

**判定**：

- `getFightSide` 从 Redis `hget` 取双方快照，取不到则同步回源——**懒加载是对的**（稳态不预拉全服玩家）。
- 但 `syncOppInfo` 是**同步调用且无超时**，对端服已下线/网络抖动时整条调用悬挂；`rpcResult` 没有任何"降级为轮空/判负"的分支。
- 战斗结算在中心进程做（`FightEngine`），战报落 `VSRecordModel` + `FightContextModel`，回放走 `getFightPlayback`。**结算与回放分离**这一点值得保留。

### 1.5 标识与开关

```java
OPEN_CROSS = PropertyLoader.getBooleanProperty(configProps, "config.open_cross", false);
validCrossServerId(id)   → id.startsWith("cross$") && split("$").length >= 3
parseCrossServerId(id)   → ["cross", oprGroup, serverId]
getCrossPlayerIdentify(crossServerId, avatarId) → crossServerId + "_" + avatarId
getCrossServerIdentifier(id) → "globalClient-" + id
```

`cross$` 在整个 Java 工程只出现 **3 处**——说明这套 ID 约定用得很少，但它是**跨服与合服共用的分组标识**（`oprGroup` 既是跨服组又是合服组）。代价是合服后 `oprGroup` 变化，跨服侧的历史数据（Redis key、战报）需要迁移。

---

## 2. 机制评价

### 2.1 值得保留的 5 条

| # | 机制 | 为什么保留 | 新版落点 |
|---|---|---|---|
| X1 | 控制面 / 数据面分离 | 中心只编排，重数据外置；中心重启不丢业务数据 | `hub` 只管编排与合并，玩家数据仍在 `db`；hub 自身状态落 snapshot |
| X2 | 懒加载回源 | 稳态不预拉，跨服战只拉对手两人 | 保留，但加 TTL + 超时（见 §3.3） |
| X3 | 结算与回放分离 | 战报是可重放的独立产物，不依赖在线状态 | 结算在 hub，战报落 `fight_record`，回放独立读 |
| X4 | 注解/注册式接入 | 加跨服能力不改 `CrossServer.java` | `schema` 一行 + `handler` 一个，同构 |
| X5 | 单开关能快速止损 | 出问题一个配置关掉全部跨服 | 保留"总闸"，但降级为三级开关的顶层（见 §3.6） |

### 2.2 必须改的 5 条

| # | 问题 | 新版对策 |
|---|---|---|
| Y1 | 中心全量轮询 | 增量推送 + 版本号 + 按需对齐（§3.2） |
| Y2 | 中心纯内存 | 状态落 snapshot，冷启动从盘恢复（§3.7） |
| Y3 | 同步回源无超时 | 两阶段 + TTL + 超时降级（§3.3） |
| Y4 | 单开关不可灰度 | 分组 / 特性 / 比例三级（§3.6） |
| Y5 | 字符串拼 ID 做路由 | `(gid, sid)` 整数二元组 + 结构化玩家标识（§3.4） |

---

## 3. 优化设计（skynet 版）

### 3.1 拓扑：一个 hub 服务取代三个进程

```
        ┌────────────────────────────────────┐
        │  service/hub.lua  （唯一跨服中心）  │
        │  · 排行合并（增量）                 │
        │  · 跨服组注册表 (gid → {sid...})    │
        │  · 开关三级                         │
        └───────┬──────────────────┬─────────┘
                │ skynet.send/call │
     ┌──────────┴───┐      ┌───────┴────────┐
     │ agent (zone A)│      │ agent (zone B) │
     └──────────────┘      └────────────────┘
                │
     ┌──────────┴────────────┐
     │ service/db.lua        │  玩家数据（已有）
     └───────────────────────┘
```

**为什么不照搬 global 进程 + Redis**：

| 项 | 原服 | skynet 版 | 理由 |
|---|---|---|---|
| 中心 | 独立 JVM 进程 + 自定义 RPC | `hub` 服务 + `skynet.call` | skynet 服务本身就是隔离的执行单元，跨进程收益为零 |
| 共享数据 | Redis（zset/hash） | hub 内存 + snapshot 落盘 | 单机部署下 Redis 是纯开销；需要多机时再换 `db` 后端，不改接口 |
| 战斗 | 独立 fight 进程 | hub 内结算（结算版） | 无逐帧模拟后，结算是一次纯函数调用，不需要独立进程 |
| 传输 | `globalClient` 长连 | skynet 消息 | 自带、可靠、有超时语义 |

**唯一保留的"进程边界"是 zone**：`(gid, sid)` 表示一个逻辑分区。同一 skynet 进程内可以跑多个 zone（`sid` 不同，`db` 前缀不同），这样"跨服"在开发和验收阶段就能在一台机器上跑通，不需要真的部署两套。

### 3.2 排行：增量推送 + 版本 + 按需对齐

**核心改动：从"中心拉"改成"服推 + 中心按需对齐"。**

```
写路径（事件驱动，非定时）
  agent 里分数变化 → cross.submit(rankKey, val) → hub 更新 zset → 返回 (rev, myRank)

读路径（按需）
  client 请求 u.crossRank → agent → hub.getRank(rankKey, page)
  若 hub 认为某 sid 数据 age > stale_ms → 顺手给该 sid 发 refresh（异步，不阻塞本次读）

对齐路径（低频兜底）
  每 align_gap（默认 5 分钟）hub 检查一次各 sid 的 last_seen，
  只对"沉默太久"的 sid 发对齐请求；活跃 sid 不打扰
```

对比：

| 指标 | 原服 | 新版 |
|---|---|---|
| 稳态网络量 | N×200 / 5min（定时，与变化无关） | 只在有变化时推 1 条 |
| 新鲜度 | 5 分钟 | 提交即生效（同进程内是调用返回） |
| 合并复杂度 | 全量去重 + 全量排序 | 有序插入 O(log n)，只维护 top-K |
| 读阻塞 | 合并期持锁 | 读写分离，读走快照引用 |
| 中心重启 | 排行清空 | snapshot 恢复 + 按 `rev` 增量补齐 |

**幂等与乱序**（原服完全缺失）：每条提交带 `(sid, seq)`，hub 维护 `last_seq[sid]`，`seq <= last_seq` 直接丢弃并返回当前值。这让"重试"变成安全操作。

**top-K 的截断策略**：原服 `GLOBAL_RANK_LEN = 200` 硬截断，玩家掉出 200 后无排名。新版保留 top-200 用于列表，但**额外维护"我在第几名"**（按 `(sid, uid)` 查询），避免"掉榜即失联"。

### 3.3 跨服战：两阶段 + TTL + 不阻塞

```
阶段 1  prepare（双方各自，异步）
  A 服: hub.prepare(matchId, sidA, uidA, fightSideA)   → 存 hub, TTL=30s
  B 服: hub.prepare(matchId, sidB, uidB, fightSideB)
  任一方 5s 内未到 → hub 标 match 为 timeout

阶段 2  settle（hub 内，纯函数）
  两侧齐 → settle(matchId) → 结算 → 写 fight_record → 推 EVENT 给双方
  任一侧缺失 → 按 tactic（配置）降级：
      "wait"   → 返回 {pending=true}，客户端显示"对手准备中"
      "bypass" → 判轮空，直接给守方胜
      "fail"   → 判负并记日志
```

**与原服的差别**：原服是"一个调用里同步取两侧 + 结算 + 返回"，任何一侧缺失就悬挂；新版把"取数据"和"结算"拆成两次调用，中间有 TTL 和降级策略，**调用永不悬挂**。

**战报**：`settle` 产出 `{seed, sides, rounds?}` 存 `fight_record`。结算版没有 rounds，只有 `{winner, damage, drops}`；将来接逐帧战报时只是往这个字段里填数组，接口不变。

### 3.4 标识：整数二元组 + 结构化玩家 ID

```lua
-- 原服：cross$oprGroup$serverId + "_" + avatarId   （不可逆，需 split）
-- 新版：
zone  = { gid = 1, sid = 3 }                 -- 都是小整数
pid   = { zone = zone, uid = 10086 }         -- 结构化，不拼字符串
key   = string.format("%d:%d", gid, sid)     -- 仅在需要字符串键时生成（Redis/lua table）
```

理由：字符串拼接一旦 `avatarId` 里含有分隔符就歧义；整数二元组可以比较、可以哈希、可以直接做分片键。`cross$` 这层壳完全不需要。

**合服兼容**：`gid` 与 `sid` 分离后，合服只改 `sid → gid` 的映射表，不迁移历史数据（历史数据按 `sid` 归档，读时映射）。原服把两者绑在一个 `oprGroup` 里，正是合服要迁移数据的根因。

### 3.5 开关：三级

```lua
cross = {
  enabled = true,                       -- L1 总闸（对应原服 OPEN_CROSS）
  groups  = { [1] = { enabled = true, features = { rank = true, fight = false, mail = true } } },
  rollout = { rank = 100, fight = 0 },  -- L3 按百分比灰度（0~100）
}
```

判定顺序：`总闸 → 分组 → 特性 → 比例`。任何一级关闭即返回"跨服未开启"，**客户端表现为功能入口灰掉，不是报错**——这是原服"一刀切"最容易挨骂的地方。

### 3.6 存储：hub 状态落 snapshot

hub 只持三类状态：`rank zset`、`last_seq`、`match` 表。全部可序列化，`snapshot_interval`（默认 60s）+ 退出时落盘。冷启动先恢复再对外服务，避免原服"重启后排行空窗"。

不引入 Redis 的代价：hub 只能是单点。**这是有意的取舍**——单机部署下 Redis 提供的"多进程共享"用不上；真要多机时，`hub` 的 `store` 抽一层换成 `db`/Redis 即可，接口不变（与 `shared/db_driver_*.lua` 同一手法）。

---

## 4. 最小可运行（本次落地范围）

### 4.1 交付物

| 文件 | 内容 | 规模 |
|---|---|---:|
| `service/hub.lua` | 排行提交/查询、`last_seq` 幂等、snapshot 落盘、三级开关 | ~180 行 |
| `service/handler/cross.lua` | `u.crossSubmit` / `u.crossRank` 两个动作 | ~50 行 |
| `conf/schema.xlsx` | 新增 2 个 action（aid 16/17） | 2 行 |
| `test/test_cross.lua` | 4 条断言 | ~80 行 |

### 4.2 接口

```lua
-- hub 对外
hub.submit(gid, sid, seq, rankKey, uid, score)  -> { ok, rev, rank }         -- 幂等
hub.rank(gid, rankKey, page, size)              -> { rev, rows, me }         -- 只读
hub.set_switch(path, value)                     -> { ok }                    -- 三级开关
hub.snapshot()                                  -> { ok }                    -- 手动落盘（测试用）

-- 客户端动作
u.crossSubmit { rankKey, score }  -> { rank, rev }
u.crossRank   { rankKey, page }   -> { rev, rows = [{uid, name, score, rank}], me }
```

### 4.3 验收

```bash
make -C ch13_palace test-cross
```

期望 4 条：

| # | 断言 | 证明什么 |
|---|---|---|
| T1 | 两个 zone（sid=1/2）各提交 1 条 → `rank()` 返回 2 行且按分数降序 | 合并正确 |
| T2 | 同一 `(sid, seq)` 重复提交 → 分数不变、`rev` 不变 | 幂等 |
| T3 | `seq` 回退提交 → 被丢弃，返回当前 `rev` | 乱序防护 |
| T4 | `switch.rank=false` → `rank()` 返回"功能未开启"，`submit` 仍可写 | 三级开关独立生效 |

并保证既有 327 PASS 不回归。

### 4.4 明确不做（本次）

| 不做 | 原因 | 触发条件 |
|---|---|---|
| 跨服战 `settle` | 依赖 `fight` handler（服务端 M2 缺口） | U4 完成后 |
| 世界 Boss / 公会战 | 需要定时编排 + 全服广播 + 结算排名，是"活动系统"而非"跨服设施" | M3 之后单独立项 |
| 跨服邮件/喇叭 | 依赖 `mail` 域（新版未做） | 有 `mail` 之后 |
| hub 多实例/分片 | 单机部署不需要 | 有第二个物理机时 |
| Redis 后端 | 同上 | 同上 |

**留的钩子**：`hub` 的 `store` 与 `transport` 都是可替换函数；`settle` 只留 `error("not implemented")` 与 schema 注释，不写半成品。

---

## 5. 工作量

| 项 | 内容 | 服务端人日 |
|---|---|---:|
| H1 | `hub.lua`（提交/查询/幂等/开关/snapshot） | 2 |
| H2 | `handler/cross.lua` + schema 2 动作 + 导表 | 0.5 |
| H3 | `test_cross.lua` 4 条 + 接入 `make verify` | 0.5 |
| **合计（本次）** | | **3** |

若将来补全跨服战：`settle` + `fight_record` + 双方推送约 **3~4 人日**；补跨服邮件/喇叭取决于 `mail` 域，约 **1~2 人日**。

---

## 6. 一句话

**原服跨服做对了"控制面/数据面分离"和"懒加载回源"，但用"中心定时全量轮询"实现排行、用"同步阻塞取数据"实现跨服战——前者让新鲜度永远落后一个周期，后者让对端掉线变成中心悬挂。新版把这两条都对调了：排行改"推"，战斗改"两阶段"，并用整数二元组取代字符串拼 ID。本次只落地排行这一条最短链路（3 人日），把接口和开关留好，跨服战等 `fight` 就位再填。**
