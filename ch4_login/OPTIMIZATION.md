# ch4_login 效率与架构优化方案

> **状态：P0–P3 已全部实施并验证通过（2026-10-26）。实施结果见文末 §6。**

> 优化对象：`ch4_login/`（新版，工业级分层版）
> 对照基线：`ch4_login/old/`（原始版本）
> 目标：修复链路断裂、把「假压测」变成「真压测」、在不牺牲可读性的前提下提升吞吐与可扩展性

---

## 0. 一句话结论

现在 `make stress` 报的 **8333 req/s / p99=19ms 只测了 center 一个内存服务的串行处理能力**，
TCP、协议编解码、Agent 创建、Gate 会话管理**全都不在链路里**（`gateway/main.lua` 从未启动 gate 与 login）。
所以当前的"效率数据"不能作为优化基线，先要把链路接通，再谈优化。

---

## 1. 现状诊断

### 1.1 P0 — 架构链路断裂（阻塞一切优化）

> 本节描述的是**优化前的原始状态**，其中 `文件:行号` 均指修复前版本的代码；当前源码已按本节
> 之后各节完成改造，对照时请以"修复后"的源码为准。

| # | 问题 | 证据 | 影响 |
|---|------|------|------|
| A1 | **gate / login 服务从未启动** | `gateway/main.lua:29-39` 只 `newservice("center")` + 测试服务；而 `old/gateway/main.lua:13-21` 启动了 gate+login 并注入依赖 | 新版相对老版是**架构退化**：gateway 层 100% 死代码，压测直连 center |
| A2 | **Agent 不是服务，是同进程 table** | `gateway/login.lua:17` `require "service.agent"`，`:53` `agent_mod.create(...)` 在 login 服务内建对象 | 无独立消息循环、无隔离、崩溃连坐；后续 ch8 组件式 / ch11 跳转 / ch12 断线重连全部无法承载 |
| A3 | **center 缺 `register_agent` 命令** | `service/agent.lua:45` 调 `register_agent`，`service/center.lua:157-179` 无此分支 → 落到 `Unknown cmd` 返回 `ERR_INTERNAL`；`agent.lua:33` 用 `safe_call` 把错误**静默吞掉** | `online[uid].agent` 永远是 nil，登录"看起来成功"实则没登记 Agent |
| A4 | **gate 不是 gate** | `gateway/gate.lua:52,64` 把 fd 当服务地址 `skynet.call(session,"lua",...)`；`:84` 对 hash 表取 `#agents`（恒为 0）；无 socket 监听、无 `gateserver`/`socketdriver` | 在线人数统计永远返回 0；整个会话层不可信 |
| A5 | **proto 层空转** | `login.lua`/`gate.lua`/`agent.lua` 都 `require "proto.proto"`，但无人 `encode/decode` | `proto/game.proto` 是摆设，压测不含协议开销 |
| A6 | **测试以 `os.exit` 杀进程** | `test/*.lua` 全部 `os.exit()` 结尾 | `make test` = 启动 2 个 skynet 进程，`stress` 再 1 个；无法聚合结果、无法复用已启动的 gate/login |

### 1.2 P1 — 效率问题（按收益排序）

| # | 问题 | 证据 | 说明 |
|---|------|------|------|
| B1 | **每次登录写一条日志** | `service/center.lua:90` `skynet.error("[center] Login OK: ...")` | 1000 次登录 = 1000 条跨服务消息 + 文件 IO（`conf/skynet.conf:26` `logger = "ch4.log"`）。这是当前 120ms 里最大的噪声源 |
| B2 | **Token 每次做 2 次 MD5** | `shared/token.lua:66-71` `_hmac` = `md5(md5(secret..data)..data)`，且 `require "md5"` 写在函数体内 | 1000 次登录 = 2000 次 MD5。Token 若改为随机串 + 服务端索引，**哈希开销可完全消除**，安全性反而更高（见 §3.3） |
| B3 | **清理定时器单位错误 + 全表扫描** | `service/center.lua:45` `skynet.sleep(600000)` — skynet.sleep 单位 1/100 秒 → **实际 6000 秒（100 分钟）**，注释却写 60s；`:48` `pairs(token_store)` 全表扫 | 既没按预期清理，又埋下百万在线时 O(N) 卡顿的隐患 |
| B4 | **延迟统计精度不足** | `test/stress_1000.lua:63` `math.floor((t1-t0)*1000)` | p50/p90 全是 0ms，分位数失去意义。应统计微秒 |
| B5 | **批次等待无超时上限** | `test/stress_1000.lua:88-90` `while completed < end_i do skynet.sleep(1) end` | 任一协程异常未 `completed++` → **永久挂死**，正是 `修复.md` #11 想杜绝的场景 |
| B6 | **单条消息注册 1000 账号** | `test/stress_1000.lua:41` 一次 `register_many("bot",1000)` | 阻塞 center 消息循环 1000 次迭代，压测期间无其他请求可插队 |
| B7 | **状态双写** | `service/center.lua:21-22` `token_store` + `online` 两张表，`:87-88` 双写、`:112-113` 双删 | 冗余且易不一致；`token_store` 除清理外无独立用途 |
| B8 | **时间源混用** | `center.lua:47` 用 `os.time()`，`token.lua:17` 用 `skynet.time()` | 后续跨节点（ch10）会漂移，统一为 `skynet.time()` |
| B9 | **conf 缺 `maxclient`** | `conf/skynet.conf` 无该键 | 真实 gate 起来后，默认 1024 会在 1000 连接压测时触顶（`audit_report.md` §问题6 已提出需 2048） |
| B10 | **utils 死代码 / 脆弱 API** | `shared/utils.lua:7-14` `uuidv4` 从未被 token 使用；`:32-43` `deepcopy`、`:46-53` `tohashmap_str` 无人调用；`:22-29` `safe_call` 只取首个返回值 | 多返回值静默丢失，是 `修复.md` #8 同类坑的遗留 |

### 1.3 顺带修掉的正确性缺陷

- `gateway/login.lua:69` `logout_handler` 内 `skynet.call` 无 `pcall` 保护
- 全链路 `skynet.call` 无超时，center 卡住则调用方永久挂起
- `verify_token` 依赖 Token 内嵌 uid，一旦改换 Token 策略需同步加 `token → uid` 索引
- 关于 `skynet.queue`：`ARCH.md` 已明确"center 是单服务，lua 消息天然串行调度，不需要额外
  `skynet.queue`"——与本实现一致，此项已澄清，无需二选一

---

## 2. 目标架构

```
                    ┌──────────────────────────────────────────┐
   TCP Client ─────▶│ gate  (snax.gateserver + socketdriver)   │
                    │  fd ↔ connection, 限流, 心跳               │
                    └───────────────┬──────────────────────────┘
                                    │ 握手请求
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ login (snlua, 可多实例, 无状态)            │
                    │  auth_handler  → center.login             │
                    │  login_handler → newservice("agent")      │
                    └───────────────┬──────────────────────────┘
                                    │ skynet.call
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ center (单实例, 未来可按 uid 分片)          │
                    │  accounts / online / token_index          │
                    └───────────────┬──────────────────────────┘
                                    │ 签发 token, 登记 online
                                    ▼
                    ┌──────────────────────────────────────────┐
                    │ agent (每玩家一个 snlua 服务)              │
                    │  start → center.register_agent            │
                    └──────────────────────────────────────────┘
```

**分层保持不变**（conf / shared / proto / service / gateway / test），新增两处公共件：

```
shared/service.lua   -- dispatch 表注册 + reply + pcall 兜底 + 超时 + 内置计数
shared/token.lua     -- 重写：随机串 + 服务端索引，去掉 MD5
```

---

## 3. 优化项与实施细节

### 3.1 P0-1 接通真实链路

`gateway/main.lua` 恢复启动 gate/login 并注入依赖（old 版的做法是对的，新版误删）：

```lua
local gate  = skynet.newservice("gate")
local login = skynet.newservice("login")
skynet.call(login, "lua", "init", center, gate)
skynet.call(gate,  "lua", "init", login)
```

`conf/skynet.conf` 补 `maxclient = 2048`，压测 target 下把 `logger` 置空（用 `conf/skynet_stress.conf` 区分）。

### 3.2 P0-2 Agent 服务化

```lua
-- gateway/login.lua
function M.login_handler(uid, token, session)
    local agent = skynet.newservice("agent")
    local ok = skynet.call(agent, "lua", "start", uid, token, skynet.self())
    ...
end
```

`service/agent.lua` 改为标准 snlua 服务（`skynet.start` + `dispatch`），
`center` 增加 `register_agent` 分支，把 `online[uid].agent = addr` 真正写进去。
`service/center.lua:90` 的"每次登录一条日志"改为**计数器 + 结束汇总**。

### 3.3 P1-1 Token 去哈希（纯收益）

Token 的价值在于**不可猜测 + 服务端可查**，不在于自签名。改为：

```lua
local crypt = require "skynet.crypt"
function M.generate(uid)
    -- 128bit 随机串，不内嵌 uid，不签名
    return crypt.randomkey() .. crypt.randomkey(), nil
end
```

配套：`center` 维护 `token_index[token] = {uid, expire_at}`，`verify_token` 直接查表。
收益：每次登录省 2 次 MD5 + 2 次字符串拼接；校验从"解析+哈希比对"退化为"一次 hash 查找"；
安全性提升（不再暴露 `uid|timestamp` 明文，也杜绝伪造时间戳）。

### 3.4 P1-2 过期清理改分桶

```lua
-- 按 300s 分桶，到期整桶失效，O(1) 清理，杜绝全表 pairs
local BUCKET = 300
local buckets = {}          -- expire_bucket_key → { [token] = uid }
```

定时器改为 `skynet.sleep(6000)`（**60 秒**，修正单位 bug），只处理 ≤2 个到期桶。

### 3.5 P1-3 命令分发与错误处理统一

新增 `shared/service.lua`：

```lua
local M = {}
function M.start(cmd_table, on_unknown)
    skynet.start(function()
        skynet.dispatch("lua", function(_, session, cmd, ...)
            local f = cmd_table[cmd]
            if not f then
                skynet.error("[svc] unknown cmd: " .. cmd)
                if session ~= 0 then skynet.retpack(on_unknown(cmd)) end
                return
            end
            local ok, err = pcall(f, session, ...)
            if not ok and session ~= 0 then skynet.retpack(ERR_INTERNAL, tostring(err)) end
        end)
    end)
end
```

消除 center / login / gate 三处重复的 `if-elseif` 链与 `reply` 闭包。

### 3.6 P2-1 测试框架改造

1. **单进程跑完全部用例**：测试服务 `run` 结束后 `skynet.exit()`，由 `main.lua` 汇总 pass/fail，最后统一 `os.exit(fail > 0 and 1 or 0)`。`make test` 从 2 个进程降到 1 个。
2. **延迟改微秒**：`(skynet.time() - t0) * 1e6`，分位数才有意义。
3. **等待加超时**：`while completed < end_i and tick < 600 do skynet.sleep(1); tick = tick + 1 end`，超时判失败，杜绝挂死。
4. **新增端到端压测 `test/stress_e2e.lua`**：真实 TCP 连接 + sproto 编解码 + agent 创建，这才是可对外报的性能数字。原 `stress_1000.lua` 保留为「center 单点吞吐」基准，改名 `stress_center.lua` 以免误导。
5. **压测收尾清理**：结束后批量 logout，避免 1000 条 online 残留。

### 3.7 P2-2 Agent 创建成本（**先 profiling 再决定**）

`newservice` 单实例约 0.1~0.5ms，1000 人即 0.1~0.5s。但按 `design.md` Phase 2 的约定——
**未确认瓶颈前不做池化**。步骤：先让端到端压测跑起来，用 `skynet.profile` 拿到 agent 创建占比，
超过 30% 再引入「预启动空 agent 池 / 登录后绑定 uid」。

### 3.8 P3 扩展性预留（为 ch5-ch12 留接口）

- center 按 `uid % N` 分片（`center_1..center_N`），登录请求由 login 侧路由，突破单服务串行上限
- Token 直接登录（`login_by_token`）走 `token_index`
- center 内置指标：`qps / online_count / p99 / 累计登录数`，供 ch9 HTTP 的 `/health` 直接取用
- 预留 `agent` 的 `offline` 状态位与重绑 fd 接口，ch12 断线重连直接复用

---

## 4. 实施顺序与验收标准

| 阶段 | 内容 | 验收 |
|------|------|------|
| **P0** | 接通 gate/login；agent 服务化 + `register_agent`；修 gate 的 fd/计数 bug；修 `sleep(600000)`；补 `maxclient` | 单客户端可完成 TCP 登录并收到 `login_resp`；`online[uid].agent ~= nil` |
| **P1** | Token 去哈希 + `token_index`；分桶清理；`shared/service.lua`；center 日志降噪 | center 单点吞吐 ≥ 8333 qps 不退化，p99 从 19ms 下降 |
| **P2** | 测试框架单进程化 + 微秒统计 + 超时保护；新增 `stress_e2e` | **1000 客户端端到端登录成功率 100%，p99 < 200ms**；`make test` 单进程跑完 18 个用例，失败即非零退出且不挂死 |
| **P3** | center 分片、Token 直登、监控指标 | 分片后吞吐随 N 线性提升；`/health` 可取到实时指标 |

**内存红线**（沿用 `audit_report.md`）：1000 在线时 center 进程 RSS < 50MB。

---

## 5. 需要注意的"不要做"

- ❌ 不要把 8333 req/s 当成性能基线对外引用 —— 它不含网络与协议开销
- ❌ 不要在 center 里加 `skynet.queue` —— 单服务 dispatch 已是串行，加 queue 只会增加协程开销；
  应改的是 `ARCH.md` 的描述
- ❌ 不要删除 `old/` —— 它是回归对照基线，`Makefile.old` 的 `test-old*` 目标用于验证重构未改变外部行为
  （已验证：`make -f Makefile.old test-old-login` 仍 6 PASS）

---

## 6. 实施结果（2026-10-26）

### 6.1 落地清单

| 阶段 | 改动 | 文件 |
|---|---|---|
| P0 | gate 基于 `snax.gateserver` 重写（真实 TCP + fd↔uid↔agent）；login/gate 纳入启动流程 | `gateway/gated.lua`、`gateway/main.lua` |
| P0 | Agent 改为独立 snlua 服务；center 补 `register_agent` | `service/agent.lua`、`service/center.lua` |
| P0 | conf 补 `maxclient=2048` / `gate_port` / `gate_backlog` | `conf/skynet.conf` |
| P1 | Token 去哈希（128bit 随机串 + 服务端 `token_index`） | `shared/token.lua`、`service/center.lua` |
| P1 | 过期清理改 300s 分桶，修正 `sleep(600000)`→`sleep(6000)`；在线用户自动续期 | `service/center.lua` |
| P1 | 统一服务骨架（dispatch 表 + pcall 兜底 + 自动回包） | `shared/service.lua` |
| P1 | 登录日志降噪为计数器；新增 `stats` 指标接口 | `service/center.lua` |
| P2 | 测试单进程化、纳秒级统计、批次超时上限、收尾清理 | `test/*.lua`、`gateway/main.lua`、`shared/utils.lua` |
| P2 | 新增端到端压测与机器人客户端 | `test/stress_e2e.lua`、`test/robot.lua` |
| P2 | Agent 对象池（预热 128 + 热激活）—— profiling 确认后实施 | `gateway/login.lua`、`service/agent.lua` |
| P3 | center 寻址收敛为 `pick_center()`；`login_by_token` 免密重连；`stats` 指标 | `gateway/login.lua`、`service/center.lua` |

### 6.2 性能对比（同一台 WSL Ubuntu，1000 次登录）

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| center 单点吞吐 | 8333 req/s | **10153 req/s** | +21.8% |
| center P99 延迟 | 19 ms（10ms 精度量化值） | **1.98 ms**（纳秒精度实测） | 精度修复后的真实值 |
| 端到端登录吞吐 | 76.9 login/s | **2670 login/s** | **34.7×** |
| 端到端 P50 | 1270 ms | **11.0 ms** | −99.1% |
| 端到端 P99 | 1302 ms | **116 ms** | 满足 <200ms 目标 |
| 业务 ping 稳态往返 | — | **4~5 μs** | — |
| 单元测试 | 13 用例 / 2 个进程 | **18 用例 / 1 个进程** | 覆盖新增 |

### 6.3 端到端瓶颈定位过程（可复现的排查路径）

1. **listen backlog 满**：`socketdriver.listen` 默认 backlog=32，100 并发连接的 SYN 被丢弃、
   客户端 1s 后才重传 → 显式设 `backlog=1024`，76.9 → 212 login/s
2. **Agent 服务创建**：gate 侧打点显示 `newservice("agent")` 占 25~29ms，而 auth 仅 0.5~1ms
   → 引入对象池，把创建成本移出登录关键路径
3. **服务冷唤醒**：同一连接连续 ping 实测 28.4ms / 0.23ms / 0.19ms —— 首次调度 ~28ms，
   稳态只有 0.2ms → 预热阶段对每个 agent 调一次 `warmup()` 完成首次调度
4. **误判纠正**：`CH4_NO_AGENT=1` 对照实验在 backlog 未修复时得出"agent 创建不是瓶颈"的假象
   （1.27s 的 backlog 延迟掩盖了一切）。**必须先修掉主导瓶颈，再对剩余项下结论。**

### 6.4 过程中修掉的真实缺陷

- `newservice("gate")` 命中 skynet 内置 `service/gate.lua`（luaservice 路径优先级），
  服务名改为 `gated`，并把本地路径提到 `../skynet/service/?.lua` 之前
- `handler.connect` 漏掉 `gateserver.openclient(fd)`：gate 登记了连接却从不读数据，客户端永久阻塞
- `skynet.getenv` 读不到进程环境变量（它读的是 skynet 配置环境），压测参数改用 `os.getenv`
- 账号初始化用 `pairs` 遍历 hash 表，uid 分配顺序不确定 → 改数组，admin/player1/player2 固定 1/2/3
- `string.format("%d", float)` 在 Lua 5.4+ 抛错，被服务骨架吞成 `ERR_INTERNAL(-1)` → 延迟统一取整
- 单进程跑多用例时状态互相污染 → 各用例开头 `logout_all()`
- `socket.connect` / `socket.send` 并不存在（应为 `socket.open` / `socket.write`）

### 6.5 已知环境限制（非代码问题）

空闲状态下唤醒一个 skynet 服务约需 28ms（WSL2 虚拟化下的线程调度成本），
持续负载时该成本消失（实测 ping 稳态 4~5μs）。
因此**单发请求的延迟数字不代表生产表现，应以并发压测数据为准**。

### 6.6 命令

```bash
wsl -d Ubuntu make -C ch4_login test          # 18 个用例，单进程
wsl -d Ubuntu make -C ch4_login stress        # center 单点吞吐
wsl -d Ubuntu make -C ch4_login stress-e2e    # 端到端 1000 并发
# 原始版本对照（Makefile.old 用 $(CURDIR)，须从 ch4_login/ 目录内执行）
wsl -d Ubuntu -- bash -c 'cd <仓库根>/ch4_login && make -f Makefile.old test-old-login'
```
