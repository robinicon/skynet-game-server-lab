# ch10_distributed 优化与容错设计实录

本文记录把一个「单机登录」改造成「跨进程分布式登录」时的核心设计与实测数据。
目标不是堆功能，而是把**跨节点调用这个天然不可靠的链路**变得**可观测、可降级、不雪崩**。

---

## 0. 测量方法论

跨节点延迟用 `skynet.hpc()`（`CLOCK_MONOTONIC`，纳秒级）打点，不用 `skynet.time()`
（10ms 精度，测不出亚毫秒差异）。所有耗时都是「端到端：从 gateway 发起 `dist.call`
到拿到结果」的墙钟时间（未扣除框架固定开销，是真实可观测延迟）。

判定标准：优先看**计数对齐**和**调用成功率**，而不是单看墙钟。跨节点调用返回 ok 只能
证明「有人回了包」，不能证明「目标节点真的处理了」——所以每个用例都做**双向计数对齐**
（调用方计数 == 接收方计数之和）。

---

## 1. 为什么必须包一层 dist_call（而不是裸 cluster.call）

裸 `cluster.call` 有三个致命问题，全部在 `make test-hang` 里被实测证实：

| 场景 | 裸 cluster.call | 包装后 |
|------|-----------------|--------|
| 目标服务假死（永不返回） | 调用协程永久阻塞，被 `timeout 15` 强杀（rc=124） | D3.1：1000ms 内返回 `timeout`，进程继续服务 |
| 节点名未解析 + `__nowaiting=false` | clusterd 内部 `skynet.wait()` 永久阻塞 | D3.4：500ms 内返回 `timeout` |
| 故障期间持续来请求 | 连接/协程/内存全部堆积 → 雪崩 | D4：连续失败达阈值即熔断，冷却期内 fail-fast |

### 1.1 超时保护

`dist_call.timed_call` 在一个 fork 出来的协程里跑 `cluster.call`，同时挂一个
`skynet.timeout`；谁先到谁唤醒调用方。调用方放弃等待后，已发出的请求**无法取消**
（计入 `leaked`），这是已知代价——所以必须配合熔断，避免同一目标反复堆积。

### 1.2 熔断

最简版熔断：每个 node 维护 `连续失败计数`，达到 `threshold`（默认 3）即 `open`，
冷却期（`cooldown`，默认 300cs）内直接 `circuit_open` 返回，不再发起真实调用。

实测 D4：
- D4.1 连续 3 次超时 → 状态 `open`
- D4.2 熔断期内 `center_call(ping)` → `circuit_open`
- D4.3 fail-fast 耗时 **26μs**，对照真实调用 **300+μs**（快一个数量级，避免堆积）
- D4.4 熔断期内 `center2.ping` 计数**没有增加**（确认没有产生真实跨节点请求）

### 1.3 返回值语义

裸 `cluster.call` 在网络层失败时返回**单值 `false`**（不抛异常）；远端业务返回
`(false, "bad_token")` 时返回**两个值**。约定：所有跨节点接口**至少返回 2 个值，第一个
是业务 ok**。于是 `pack.n == 1 and pack[1] == false` 唯一地表示「网络/框架层失败」。
漏掉这层约定，`local ok, err = cluster.call(...)` 会把业务结果错绑到 err。

---

## 2. 一致性哈希选节点

同一个 uid 恒定命中同一个 center，原因有二：
1. center 侧才能做**本地缓存收敛**（token 缓存、在线状态）。
2. 节点扩缩容时只迁移 `1/N` 的 key，不会全量重映射导致缓存雪崩。

**哈希函数选型是成败关键**（详见 `修复.md` 坑 2）：djb2 对短数字串分布退化成 1000/0，
改用 FNV-1a 后：

| 样本 | center1 | center2 | 偏差 |
|------|---------|---------|------|
| uid 1..1000 | 445 | 555 | — |
| uid 200001..201000 | 485 | 515 | — |
| uid 1..10000 | 4876 | 5124 | **4.96%** |

D6 实测 1000 次登录：center1=485 / center2=515，偏差 **6.0%**。

D6.4 验证同一 uid 恒定命中同一节点（一致性哈希基本保证）。

---

## 3. 本地缓存：把 O(N) RPC 压成 O(1)

gateway 在 uid 维度缓存 token（TTL 默认 30s）。重连 / 频繁登录时直接命中本地缓存放行，
不再产生跨节点校验。

D8 实测：
- D8.1 二次登录命中本地缓存（`src=cache`）
- D8.2 缓存命中**不产生**跨节点校验（`cross` 计数不变）
- D8.3 累计缓存命中 1 次

**代价**：token 被吊销后，最长有 TTL 窗口期仍然有效。对「踢下线」这类强一致需求，必须走
center 的 `del` + 广播失效，不能只靠 TTL 惰性过期。

---

## 4. send 高频路径：把同步阻塞的旁路异步掉

上报在线状态是高频操作，但登录链路是同步的。把「上报在线」从 `call` 改成 `cluster.send`
（不等回包），既去掉了对登录延迟的影响，又保留了最终一致性。

D7 实测：
- D7.1 `send` 500 次 **0.28ms** vs `call` 500 次 **94.28ms**（send 约 **337×** 快）
- D7.2 异步 send 的 500 条消息最终**全部到达**（delta=500）

---

## 5. 大包跨节点

D9 实测：128KB 字符串跨节点往返一致，耗时 **3.22ms**。说明 cluster 通道对大 payload 的
序列化/传输开销可控，登录态这类小包更不在话下。

---

## 6. 服务寻址

- D10.1 `cluster.query("center1", "center")` 拿到 center_dist 的 handle（`:9`）。
- D10.2 查询不存在的名字会**抛错**（不是返回 nil）—— 跨节点寻址失败必须用 `pcall`
  包住，不能当成「没找到」去分支。

---

## 7. 综合汇总（来自 make test 真实输出）

```
gateway : login=1106 cross=1105 cache_hit=1 send=1103 fail=0
center1 : verify=568 online=1065 online_count=1065 ping=503 echo=1
center2 : verify=537 online=538  online_count=537  ping=2   echo=0
dist[center1]: total=1077 ok=1077 fail=0 timeout=0 sc=0 leaked=0 avg=190us
dist[center2]: total=545  ok=541  fail=3 timeout=3 sc=1 leaked=0 avg=3121us
```

`dist[center2]` 的 3 次 fail/timeout 来自 D3/D4 的故障注入（故意打挂），隔离在测试阶段，
不影响正常流量（center1 全程 0 失败）。`leaked` 仅 ghost 节点 1 个（主动放弃的未解析
节点协程），符合设计预期。

---

## 8. 仍未做的（演示边界）

- `redis_auth` 默认 `memory` 后端，center 重启即丢 token；生产切 `CH10_REDIS_BACKEND=redis`。
- center 未做多副本选主 / 故障转移。
- 超时只是放弃等待，被阻塞协程计入 `leaked`，需配合健康探测 + watchdog 兜底。
