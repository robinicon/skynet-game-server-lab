# ch4_login — 账号登录与验证

> 《游戏服务器架构》第 4 章的 Skynet 实现。
> 完整链路：`TCP Client → gate → login → center → agent`

---

## 快速开始

环境：WSL Ubuntu 26.04 + 已编译的 skynet（`../skynet/skynet`）

```bash
# 单元测试（18 用例，单进程）
wsl -d Ubuntu make -C ch4_login test

# center 单点吞吐基准（不含网络/协议）
wsl -d Ubuntu make -C ch4_login stress

# 端到端压测（真实 TCP + sproto + Agent，1000 并发）
wsl -d Ubuntu make -C ch4_login stress-e2e

# 两个压测连跑
wsl -d Ubuntu make -C ch4_login bench

# 原始版本回归对照（验证重构未改变外部行为）
# 注意：Makefile.old 用 $(CURDIR) 定位 old/，必须从 ch4_login/ 目录内执行
wsl -d Ubuntu -- bash -c 'cd <仓库根>/ch4_login && make -f Makefile.old test-old-login'
```

---

## 架构

```
TCP Client
    │  2字节长度 + payload + 4字节session
    ▼
┌────────────────────────────────────────┐
│ gate  (snax.gateserver + socketdriver) │
│  fd ↔ uid ↔ agent 映射、在线计数         │
└───────────────┬────────────────────────┘
                │ 第一包 = login_req（sproto）
                ▼
┌────────────────────────────────────────┐
│ login (snlua，无状态，可多实例)           │
│  auth           → center.login          │
│  login_by_token → center（免密重连）      │
│  login_handler  → Agent 对象池取一个      │
└───────────────┬────────────────────────┘
                │ skynet.call
                ▼
┌────────────────────────────────────────┐
│ center (单实例服务)                     │
│  accounts / online / token_index        │
│  300s 分桶过期清理 / stats 指标           │
└───────────────┬────────────────────────┘
                │ 签发 token、登记 online
                ▼
┌────────────────────────────────────────┐
│ agent (每玩家一个 snlua 服务)             │
│  start → center.register_agent          │
│  client → ping / echo                    │
│  logout → 归还对象池（不销毁）            │
└────────────────────────────────────────┘
```

### 目录说明

| 路径 | 说明 |
|---|---|
| `conf/skynet.conf` | 节点配置：端口、`maxclient`、`gate_backlog`、`agent_prewarm` |
| `runtime.lua` | 配置默认值与环境变量合并（`CH4_TEST_TARGET` 等） |
| `shared/service.lua` | **统一服务骨架**：命令表 dispatch + pcall 兜底 + 自动回包 |
| `shared/token.lua` | 128bit 随机串 Token，零哈希 |
| `shared/utils.lua` | 时间工具（`us_between` 只做减法，不做时钟选择）、分位数 |
| `shared/error_code.lua` | 全局错误码 |
| `service/center.lua` | 账号 / 在线 / Token 索引 / 指标 |
| `service/agent.lua` | 玩家 Agent（独立服务 + 池化复用） |
| `gateway/main.lua` | 启动编排 + 测试结果汇总 |
| `gateway/login.lua` | 认证 + Agent 对象池管理 |
| `gateway/gated.lua` | 基于 `snax.gateserver` 的网关 |
| `test/robot.lua` | TCP 机器人客户端（压测用） |
| `test/stress_e2e.lua` | 端到端压测 |
| `test/stress_center.lua` | center 单点吞吐基准 |
| `old/` + `Makefile.old` | **原始版本**，回归对照基线，请勿删除 |

---

## 性能基线（WSL Ubuntu，1000 次登录）

| 指标 | 数值 |
|---|---|
| 端到端吞吐 | 2670 login/s |
| 端到端 P50 / P99 | 11.0 ms / 116 ms |
| center 单点吞吐 | 10153 req/s |
| center P99 | 1.98 ms |
| 业务 ping 稳态往返 | 4~5 μs |

三层瓶颈及收益拆解见 [`OPTIMIZATION.md`](OPTIMIZATION.md) §6.3：

| 步骤 | 吞吐 |
|---|---|
| 基线 | 76.9 login/s |
| + `backlog=1024` | 212 login/s |
| + Agent 对象池 | 321 login/s |
| + 冷唤醒热激活 | 2670 login/s |

---

## 关键设计决策

**1. Agent 是服务，不是 table**
原始版本在 login 服务内 `require "service.agent"` 创建对象，没有独立消息循环。现改为 `skynet.newservice("agent")`，这是 ch8 组件式、ch11 跳转、ch12 断线重连的前提。

**2. Agent 池化（profiling 后实施）**
gate 侧打点显示 `newservice("agent")` 占 25~29ms，而 auth 只有 0.5~1ms。池化后登录关键路径不再包含服务创建。登出时归还池而非销毁。

**3. 冷唤醒热激活**
skynet 服务首次被调度有 ~28ms 成本（WSL2 线程调度），第二次起降到 0.2ms。预热阶段对每个 Agent 调用一次空的 `warmup()` 完成首次调度。

**4. Token 不哈希**
`crypt.randomkey()` 生成 128bit 随机串，服务端 `token_index` 查表。省掉 2 次 MD5，且不再明文暴露 `uid|timestamp`。

**5. 时间统一用 `skynet.hpc()`**
纳秒级 `CLOCK_MONOTONIC`。`skynet.time()` 精度只有 10ms，会让分位数被量化成 0 或 10000。

**6. center 不加 `skynet.queue`**
单服务的 dispatch 本身是串行的，加 queue 只增加协程开销。如果将来 center 内部出现需要并发的阻塞调用，再考虑。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CH4_TEST_TARGET` | — | 测试目标：`test_login,test_center` / `stress_center` / `stress_e2e` |
| `CH4_E2E_COUNT` | 1000 | 端到端压测并发数 |
| `CH4_STRESS_COUNT` | 1000 | center 压测次数 |
| `CH4_AGENT_POOL` | 256 | Agent 池上限 |
| `CH4_AGENT_PREWARM` | 未设→用 `conf.agent_prewarm`(128) | Agent 预热数量；显式设置时优先级高于 conf |
| `CH4_NO_AGENT` | 0 | `1` = 跳过 Agent 创建（仅压测对照，勿用于生产） |
| `CH4_GATE_TIMING` | 0 | `1` = 打印 gate 侧分段耗时 |
| `CH4_VERBOSE` | 0 | `1` = center 输出详细日志 |

> 注意：这些必须用 `os.getenv` 读取。**`skynet.getenv` 读的是 skynet 配置环境，读不到进程环境变量。**

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 优化方案与实施结果（含完整排查路径）
- [`ARCH.md`](ARCH.md) — 架构说明
- [`修复.md`](修复.md) — 20 条缺陷修复记录
- [`audit_report.md`](audit_report.md) — 原始版本审计报告
- 技术博客：[`docs/blog/01-ch4-login-端到端登录优化实录.md`](../docs/blog/01-ch4-login-端到端登录优化实录.md)
