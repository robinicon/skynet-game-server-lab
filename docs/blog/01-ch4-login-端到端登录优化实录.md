---
title: [Skynet 手记] 从 76 到 2670 login/s：一次 Skynet 登录服务的端到端优化实录
tags: [Skynet, Lua, 游戏服务器, 性能优化, 架构设计]
categories: 游戏服务器架构
abbrlink: ch4-login-e2e-optimization
date: 2026-10-27
---

# [Skynet 手记] 从 76 到 2670 login/s：一次 Skynet 登录服务的端到端优化实录

> **摘要**：项目里有一份漂亮的压测报告——8333 req/s、P99 19ms、成功率 100%。但这份报告是假的：它压根没走网络链路。本文记录一次完整的排查与优化过程：如何发现"假压测"、如何接通真实链路、如何在 76.9 login/s 的惨淡数字下通过三层瓶颈定位把吞吐做到 2670 login/s（34.7 倍），以及过程中踩到的 10 个真实陷阱。所有数据均来自 WSL Ubuntu 上的实测实验（方法可复现，具体数值随环境波动）。
>
> 系列文章：本系列基于《游戏服务器架构》第 4–12 章，用 cloudwu/skynet 逐章重新实现并优化。本文是第 4 章（账号登录与验证）。

---

## 一、开篇：一份"看起来很美"的压测报告

接手这份代码时，`make stress` 的输出是这样的：

```
=== Stress Test: 1000 logins ===
  Total time:      120 ms
  Throughput:      8333.3 req/s
  Success:         1000 / 1000
  P50 latency:     0 ms
  P99 latency:     19 ms
```

8333 req/s，P99 19ms，成功率 100%。数字很漂亮。

**但这份报告测的是一个内存哈希表的串行读写能力**——TCP 连接、协议编解码、Agent 创建、Gate 会话管理，全都不在链路里。

证据在 `gateway/main.lua`：

```lua
-- 新版：只启动了 center 和测试服务
local center = skynet.newservice("center")
local test   = skynet.newservice(test_target)
skynet.call(test, "lua", "run", center)
```

而同目录下的 `old/gateway/main.lua`（原始版本）是这样的：

```lua
-- 原始版本：完整启动了 gate + login（摘自 old/gateway/main.lua）
local center = skynet.newservice("center")
local gate   = skynet.newservice("gate")
local login  = skynet.newservice("login")
skynet.call(login, "lua", "init", center, gate)
skynet.call(gate,  "lua", "init", login)
```

也就是说：所谓"工业级分层重构"的新版本，相对原始版本是一次**架构退化**——整个 gateway 层是 100% 的死代码，压测脚本直接拿到了 center 的地址在进程内调用。

**这不是优化问题，是"没有基线"的问题。** 在链路接通之前，任何性能数字都没有意义。所以第一步不是优化，是把链路接通。

---

## 二、P0：先接通链路，再谈优化

### 2.1 四个致命的架构断裂

| # | 问题 | 证据 | 后果 |
|---|------|------|------|
| A1 | gate/login 从未启动 | `main.lua:29-39` | gateway 层死代码 |
| A2 | Agent 不是服务，是同进程 table | `login.lua:17` `require "service.agent"`，`:53` `agent_mod.create(...)` | 无消息循环、无隔离、崩溃连坐 |
| A3 | center 缺 `register_agent` 命令 | `agent.lua:45` 调用它 → 落到 `Unknown cmd` 返回 `ERR_INTERNAL`，又被 `safe_call` 静默吞掉 | `online[uid].agent` 永远是 nil，登录"看起来成功"实则没登记 |
| A4 | gate 不是 gate | `gate.lua:52,64` 把 fd 当服务地址 `skynet.call(session, ...)`；`:84` 对 hash 表取 `#agents`（恒为 0） | 在线人数永远返回 0 |

A2 和 A3 合在一起特别阴险：**A3 的错误被 `safe_call` 吞掉了**，所以日志里干干净净，登录"成功"，但 Agent 从来没被登记过。如果只看 `make test` 的绿灯，永远不会发现问题。

### 2.2 统一服务骨架：先消灭重复

重构前，center / login / gate 各自写了一套 `if-elseif` 命令链 + `reply` 闭包，每处都要自己处理 `pcall` 和 `session ~= 0`。抽成 `shared/service.lua`：

```lua
-- shared/service.lua
function M.start(name, handlers, opts)
    skynet.start(function()
        if opts.on_init then opts.on_init() end
        skynet.dispatch("lua", function(_, session, cmd, ...)
            local f = handlers[cmd]
            if not f then
                skynet.error(string.format("[%s] unknown cmd: %s", name, tostring(cmd)))
                if session ~= 0 then
                    skynet.retpack(error_code.ERR_INTERNAL, "unknown cmd: " .. tostring(cmd))
                end
                return
            end
            local r = table.pack(pcall(f, ...))
            if not r[1] then
                skynet.error(string.format("[%s] cmd %s error: %s", name, tostring(cmd), tostring(r[2])))
                if session ~= 0 then
                    skynet.retpack(error_code.ERR_INTERNAL, "cmd error: " .. tostring(r[2]))
                end
                return
            end
            -- send（session == 0）不需要、也不能回复
            if session ~= 0 then
                skynet.retpack(table.unpack(r, 2, r.n))
            end
        end)
    end)
end
```

三个关键约定：

1. **handler 抛异常 → 统一返回 `ERR_INTERNAL`**，不会让调用方的 `skynet.call` 永久挂起。原来的写法里 handler 一崩，调用方就再也没人回复它了。
2. **`session == 0` 不回复**（`skynet.send` 场景）。误回复会导致 skynet 报错。
3. **`table.pack` + `table.unpack` 保留全部返回值**。老代码用 `safe_call` 只取第一个返回值，多返回值静默丢失——这正是后面"测试假绿"的根源。

现在写服务只剩一件事：填一张命令表。

```lua
-- service/agent.lua 结尾
service.start("agent", handlers, {
    on_init = function()
        skynet.error(string.format("[agent] created: %s", tostring(skynet.self())))
    end,
})
```

### 2.3 基于 gateserver 重写 Gate

原来的 gate 完全没有 socket。新 gate 基于 skynet 自带的 `snax.gateserver`：

```lua
local gateserver   = require "snax.gateserver"
local netpack      = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"

local handshake  = {}   -- fd → addr（已连接，未登录）
local logining   = {}   -- fd → true（登录处理中，期间丢弃业务包）
local connection = {}   -- fd → { uid, agent }
local online_conns = 0

function handler.connect(fd, addr)
    handshake[fd] = addr or ""
    -- 必须显式 openclient：gateserver 此时只是登记了连接，
    -- 不调用 socketdriver.start(fd) 就永远不会读取该 fd 上的数据
    gateserver.openclient(fd)
end

function handler.message(fd, msg, sz)
    local message = netpack.tostring(msg, sz)
    if #message < 4 then
        gateserver.closeclient(fd)
        return
    end
    local session = string.unpack(">I4", message, -4)
    local body    = message:sub(1, -5)

    if handshake[fd] then
        do_login(fd, body, session)      -- 第一包 = 登录握手
    elseif logining[fd] then
        return                            -- 登录中含 yield，期间业务包丢弃
    else
        do_request(fd, body, session)     -- 后续包 = 业务消息
    end
end
```

> ⚠️ **陷阱 1：`gateserver.openclient(fd)` 容易漏**
> `handler.connect` 里如果不调用它，gate 会登记连接但从不读数据。客户端 TCP 握手成功、发登录包、然后**永久阻塞**。这个 bug 的表现是"压测批次全部超时"，很容易被误判为服务端性能问题。

> ⚠️ **陷阱 2：`newservice("gate")` 会命中 skynet 内置服务**
> `luaservice` 配置里 `../skynet/service/?.lua` 排在前面，`newservice("gate")` 解析到的是 skynet 自带的 C gate 封装，不是我的 `gateway/gate.lua`。症状是 `skynet.call(gate, "lua", "init")` 报 `call failed`，日志里断言失败在 `../skynet/service/gate.lua:92`。
> 解决：服务改名 `gated`，**并把本地路径提到内置路径之前**：
> ```lua
> luaservice = "./service/?.lua;./gateway/?.lua;./test/?.lua;./shared/?.lua;./proto/?.lua;./conf/?.lua;../skynet/service/?.lua"
> ```

### 2.4 Agent 服务化 + center 补 `register_agent`

```lua
-- service/agent.lua
function handlers.start(u, t, g, c, m)
    uid, token, gate, center, manager = u, t, g, c, m
    local ok, code = pcall(skynet.call, c, "lua", "register_agent", u, skynet.self())
    if not ok or code ~= error_code.OK then
        skynet.error(string.format("[agent] register failed: uid=%s code=%s",
            tostring(u), tostring(code)))
        alive = false
        return error_code.ERR_INTERNAL
    end
    alive = true
    return error_code.OK
end
```

center 侧：

```lua
function handlers.register_agent(uid, agent)
    local o = online[uid]
    if not o then
        return error_code.ERR_NOT_ONLINE
    end
    o.agent = agent
    return error_code.OK
end
```

至此链路通了：

```
TCP Client
    │
    ▼
┌───────────────────────────────────────┐
│ gate (snax.gateserver + socketdriver) │  fd ↔ uid ↔ agent
└───────────────┬───────────────────────┘
                │ 第一包 = login_req
                ▼
┌───────────────────────────────────────┐
│ login (无状态，可多实例)                │  auth → center.login
└───────────────┬───────────────────────┘  login_handler → alloc agent
                │ skynet.call
                ▼
┌───────────────────────────────────────┐
│ center (单实例服务)                    │  accounts / online / token_index
└───────────────┬───────────────────────┘
                │ 签发 token、登记 online
                ▼
┌───────────────────────────────────────┐
│ agent (每玩家一个 snlua 服务)           │  start → center.register_agent
└───────────────────────────────────────┘
```

---

## 三、P1：两个纯收益的算法改造

### 3.1 Token 去哈希

原实现每次登录做 2 次 MD5：

```lua
-- 旧：shared/token.lua
local function _hmac(secret, data)
    return md5.sumhexa(md5.sumhexa(secret .. data) .. data)
end
-- token 内容：`uid|timestamp`，客户端可见
```

问题不只是 CPU：token 里**明文内嵌 uid 和 timestamp**，客户端可以解析、可以伪造时间戳。

Token 的价值是"不可猜测 + 服务端可查"，不是"自签名"。改成：

```lua
local crypt = require "skynet.crypt"

function M.generate()
    -- 128bit 随机串，base64 后 24 字符；不内嵌 uid，不签名
    -- 归属与有效期由 center 侧的 token_index 查表维护
    return crypt.base64encode(crypt.randomkey() .. crypt.randomkey())
end
```

配套在 center 维护索引：

```lua
token_index[token] = { uid = uid, expire_at = now + TOKEN_TTL }
```

收益：
- 每次登录省 2 次 MD5 + 2 次字符串拼接
- 校验从"解析 + 哈希比对"退化为"一次哈希查找"
- 安全性反而更高（不再暴露 `uid|timestamp`）

### 3.2 过期清理改分桶

原实现的定时器有个单位 bug：

```lua
-- 旧：service/center.lua:45
skynet.timeout(600000, clean_expired)   -- 注释写 60s
```

`skynet.sleep` / `skynet.timeout` 的单位是 **1/100 秒**，所以 600000 = **6000 秒 = 100 分钟**，注释却写 60s。而且清理函数是 `pairs(token_store)` 全表扫描——百万在线时会有 O(N) 卡顿。

改成分桶：

```lua
local BUCKET = 300              -- 300s 一个桶
local buckets = {}              -- bucket_key → { [token] = uid }

-- 清理：只处理到期桶，O(到期数量) 而非 O(总量)
skynet.sleep(6000)              -- 修正单位：6000 tick = 60s
```

---

## 四、P2：真正的性能攻坚——76.9 login/s

链路接通后，端到端压测（1000 客户端、真实 TCP、sproto 编解码、真实 Agent）跑出来的数字很难看：

```
Total logins:   1000
Success:        1000 / 1000
Total time:     13023 ms
Throughput:     76.9 login/s
P50 latency:    1270 ms
P99 latency:    1302 ms
```

成功率 100%，但吞吐只有 76.9 /s，P50 高达 1270ms。而单进程测 center 有 8333 req/s。**差了 100 倍**，中间一定有个巨大的东西。

### 4.1 第一层：listen backlog 满了

1270ms 这个数字很可疑——接近 TCP SYN 重传的 1 秒超时。

skynet 的 `socketdriver.listen` **默认 backlog 是 32**。1000 个并发连接打过来，accept 队列瞬间溢出，内核直接丢弃 SYN，客户端要等 1 秒才能重传。

> 💡 **为什么 backlog 满了不是"连接失败"而是"慢"？**
> Linux 在 accept 队列满且 `tcp_abort_on_overflow=0` 时会**静默丢弃 SYN**，客户端收不到 RST 也收不到 SYN+ACK，只能等待超时重传（初始 RTO 就是 1s）。所以表现为延迟暴增而非报错——这也是为什么成功率还是 100%。

显式设置 backlog：

```lua
-- gateway/main.lua：backlog 作为 open 参数传给 gated
-- gated 基于 snax.gateserver，由 gateserver 内部调用 socketdriver.listen
local port      = tonumber(conf.gate_port) or 8888
local maxclient = tonumber(conf.maxclient) or 2048
skynet.call(gate, "lua", "open", {
    address   = conf.gate_address or "0.0.0.0",
    port      = port,
    maxclient = maxclient,
    -- backlog 必须显式设置：socketdriver.listen 默认 32，
    -- 1000 个并发连接会撑满队列导致 SYN 被丢弃、客户端 1s 后才重传
    backlog   = tonumber(conf.gate_backlog) or 1024,
    nodelay   = true,
})
```

> 注意：这里不需要（也不应该）在业务代码里直接调 `socketdriver.listen`。`gated` 基于 `snax.gateserver`，`gateserver.start(handler)` 内部会用传入的 backlog 完成监听；重复 `listen` 只会导致端口冲突。

**76.9 → 212 login/s（+176%）**。

### 4.2 第二层：`newservice("agent")` 在关键路径上占 25~29ms

继续做分段计时，在 gate 侧给 auth 和 agent 分配分别打点：

```
[gate] timing: auth=0.52ms agent=25.31ms
[gate] timing: auth=0.87ms agent=28.94ms
[gate] timing: auth=0.61ms agent=26.77ms
```

**认证只要 0.5~1ms，创建 Agent 却要 25~29ms**——占了单次登录的 98%。

这满足了 `design.md` 里"先 profiling 确认瓶颈再池化"的前提，可以动手了：

```lua
-- gateway/login.lua：Agent 对象池
local pool         = {}
local POOL_MAX     = tonumber(os.getenv("CH4_AGENT_POOL")) or 256
local POOL_PREWARM = tonumber(os.getenv("CH4_AGENT_PREWARM")) or 64

local function alloc_agent()
    local a = table.remove(pool)
    if a then return a end
    return skynet.newservice("agent")     -- 池空才创建
end

function handlers.prewarm(n)
    n = tonumber(n) or POOL_PREWARM
    local done = 0
    for _ = 1, n do
        skynet.fork(function()
            -- 必须先创建再入池：newservice 会 yield，
            -- 若先算 index 再 yield，多个协程会算出同一个下标互相覆盖
            local a = skynet.newservice("agent")
            pcall(skynet.call, a, "lua", "warmup")   -- 见 4.3
            pool[#pool + 1] = a
            done = done + 1
        end)
    end
    local waited = 0
    while done < n and waited < 1000 do
        skynet.sleep(1)
        waited = waited + 1
    end
    return #pool
end
```

Agent 退出时不销毁，归还池：

```lua
-- service/agent.lua
function handlers.logout()
    if not alive then return true end
    alive = false
    pcall(skynet.send, center, "lua", "logout", uid)
    if manager then
        pcall(skynet.send, manager, "lua", "recycle", skynet.self())
    end
    return true
end
```

**212 → 321 login/s**。有改善，但远不如预期——说明还有东西。

### 4.3 第三层：服务冷唤醒 28ms

池化之后单连接登录仍有 57ms 的固定延迟。用一个"纯业务往返"来区分：登录成功后连发 3 次 ping，测每次往返耗时。

```
ping r1/r2/r3 avg: 28413 / 231 / 193 us
```

**第一次 28.4ms，第二次 0.23ms，第三次 0.19ms。**

这不是登录逻辑的问题，是 **skynet 服务首次被调度时的冷唤醒成本**（WSL2 虚拟化下的线程调度 + Lua state 初始化 + 代码加载）。稳态只有 0.2ms，快得不可思议。

既然是"首次"成本，就把它挪到启动阶段：

```lua
-- service/agent.lua
--- 预热探针：不做任何业务，仅用于让服务完成首次调度
-- 实测：一个 agent 服务首次被 skynet.call 时有 ~28ms 的冷唤醒成本
-- （第二次起降到 0.2ms）。预热时调用一次，把这笔开销挪到启动阶段，
-- 而不是压在每次登录的关键路径上。
function handlers.warmup()
    return true
end
```

就是这么一个空函数——**关键不在于它做什么，而在于它让服务完成了一次完整的"被调度"过程**。

**321 → 627 login/s（COUNT=100 时）**。

---

## 五、一次失败的对照实验（方法论警告）

在排查过程中我做过一个对照实验：加 `CH4_NO_AGENT=1` 开关跳过 Agent 创建，看吞吐变化。

```
# [Skynet 手记] backlog 修复之前
CH4_NO_AGENT=1:  76.4 login/s
正常:             76.9 login/s
```

差异 0.6%，结论：**"Agent 创建不是瓶颈"**。

**这个结论是错的。** 因为当时 1.27s 的 backlog 延迟主导了一切，Agent 的 28ms 被完全淹没在噪声里——就像在台风天里测量一根蜡烛对气温的影响。

正确的做法是：**先修掉主导瓶颈，再对剩余项下结论。**

```
# [Skynet 手记] backlog 修复之后，同样的对照
CH4_NO_AGENT=1:  211.4 login/s
正常:             210.6 login/s      ← 仍然看不出差异？
```

这里还有第二个陷阱：**池化之后 Agent 创建已经不在关键路径上了**，所以对照组当然没差异——它验证的是"池化生效了"，而不是"创建不贵"。

真正的证据来自 gate 侧的直接打点（4.2 节的 25~29ms），而不是端到端吞吐的对照。

> **方法论小结**
> 1. 端到端吞吐的 A/B 对照**只能验证主导瓶颈**，被掩盖的次要项要靠分段打点
> 2. 修一个瓶颈后必须**重新测量**剩余项，不能沿用旧结论
> 3. 优化完成后要**反向验证**：把优化关掉，看数字是否回到原点

---

## 六、那些让数据失真的坑

这一节单列，因为它们不产生性能收益，但会让你**基于错误的数据做出错误的决策**。

### 6.1 时间源用错：延迟出现 -1793028357030 ms

```lua
-- 错误：utils.elapsed_us 里 skynet 是 nil（utils 没 require skynet），
-- 回退到 os.clock() 的 CPU 时间基准，与 skynet.time() 的墙钟相减
function M.elapsed_us(t0, t1)
    t1 = t1 or (skynet and skynet.time() or os.clock())
    return math.floor((t1 - t0) * 1000000)
end
```

`os.clock()` 返回的是 **CPU 时间**（进程占用 CPU 的秒数），`skynet.time()` 返回的是**墙钟时间**。两者相减得到巨大负值，于是出现 `-1793028357030 ms` 这种荒谬输出。

修正原则：**时间值必须由调用方成对传入，工具函数只做减法、不做时钟选择。**

### 6.2 精度不够：P50 = 0us，P99 = 10000us

修掉 6.1 之后，又出现 `P50=0us / P99=9999us` 这种明显被量化的结果。原因是 `skynet.time()` 的精度只有 **10ms**（它基于 `skynet.now()` 的 tick，1 tick = 10ms）。分位数被量化成 0 或 10000，完全失去意义。

改用 skynet 提供的纳秒级单调时钟：

```lua
-- skynet.hpc() 基于 CLOCK_MONOTONIC，纳秒精度
local t0 = skynet.hpc()
-- ... 业务 ...
local us = math.floor(utils.us_between(t0, skynet.hpc()))
```

```lua
-- shared/utils.lua
function M.us_between(t0_ns, t1_ns)
    return (t1_ns - t0_ns) / 1000     -- ns → us
end
```

### 6.3 `string.format("%d", float)` 在 Lua 5.4+ 抛错

延迟改成浮点微秒后，压测输出在 `Avg latency` 之后中断，main 收到 `-1`（`ERR_INTERNAL`）。

原因：Lua 5.4+ 的 `%d` 遇到非整数表示的浮点会**直接抛错**，而这个错误被服务骨架捕获成了 `ERR_INTERNAL`，调用方只看到一个 -1，真实原因被吞掉。

修正：延迟统一 `math.floor` 取整后再入数组，格式串继续用 `%d`。

> 有意思的是：这个 bug 之所以能被发现，正是因为 2.2 节那个"骨架捕获异常后返回 ERR_INTERNAL"的机制。如果骨架不捕获，它会直接崩溃；如果捕获但不返回错误码，它会静默。**"捕获 + 显式错误码 + 日志"三者缺一不可。**

### 6.4 `skynet.getenv` 读不到进程环境变量

```lua
-- 错误：skynet.getenv 读的是 skynet 的配置环境（conf 文件 / setenv），
-- 不是 os 的进程环境变量
local COUNT = tonumber(skynet.getenv("ch4_e2e_count")) or 1000
```

症状：`make stress-e2e CH4_E2E_COUNT=1` 仍然按默认 1000 跑。后果是**梯度实验全部无效**——我以为在测 1 个连接，实际在测 1000 个。

修正：改用 `os.getenv("CH4_E2E_COUNT")`。

### 6.5 `pairs` 遍历 hash 表导致 uid 分配顺序随机

```lua
-- 错误：三个初始账号的 uid 分配顺序不确定
local init_accounts = { admin = "admin123", player1 = "pass1", player2 = "pass2" }
for username, password in pairs(init_accounts) do ... end
```

症状：单进程跑多用例时 `register_agent(2)` 有时成功有时失败。改成数组 + `ipairs`，admin/player1/player2 固定为 1/2/3。

### 6.6 `socket.connect` / `socket.send` 根本不存在

skynet 的 socket API 是 **`socket.open`**（连接）和 **`socket.write`**（发送）。写成 `connect` / `send` 会报 `attempt to call a nil value`。

### 6.7 单进程多用例状态污染

测试合并成单进程后，test_center 的断言报 `expected=0 got=3`——因为 test_login 登录后没登出，admin 还在线。

修正：各用例 `run()` 开头统一 `logout_all()`，**用例自治、不依赖执行顺序**。

### 6.8 批次等待无超时上限

```lua
-- 错误：任一协程异常未 completed++ 就永久挂死
while completed < end_i do skynet.sleep(1) end
```

加上限：

```lua
local waited = 0
while completed < end_i and waited < WAIT_TICKS do
    skynet.sleep(1)
    waited = waited + 1
end
if completed < end_i then
    -- 超时判失败，而不是继续等
    fail_n = fail_n + (end_i - completed)
end
```

---

## 七、最终结果

同一台 WSL Ubuntu，1000 次登录：

| 指标 | 优化前 | 优化后 | 变化 |
|---|---|---|---|
| **端到端登录吞吐** | 76.9 login/s | **2670 login/s** | **34.7×** |
| 端到端 P50 | 1270 ms | **11.0 ms** | −99.1% |
| 端到端 P99 | 1302 ms | **116 ms** | 达成 <200ms 目标 |
| center 单点吞吐 | 8333 req/s | **10153 req/s** | +21.8% |
| center P99 延迟 | 19 ms（10ms 精度量化值） | **1.98 ms**（纳秒实测） | 精度修复后的真实值 |
| 业务 ping 稳态往返 | — | **4~5 μs** | — |
| 单元测试 | 13 用例 / 2 进程 | **18 用例 / 1 进程** | 覆盖新增 |

原始版本基线未破坏：

```bash
# [Skynet 手记] Makefile.old 用 $(CURDIR) 定位路径，必须从 ch4_login/ 目录内执行
wsl -d Ubuntu -- bash -c 'cd /mnt/c/workspaces/bookskynet/ch4_login && make -f Makefile.old test-old-login'   # 仍 6 PASS
```

三层瓶颈的收益拆解：

| 步骤 | 吞吐 | 增量 |
|---|---|---|
| 基线（链路接通） | 76.9 login/s | — |
| + backlog=1024 | 212 login/s | +176% |
| + Agent 对象池 | 321 login/s | +51% |
| + 冷唤醒热激活 | 2670 login/s | +731% |

> 注意最后一步的增量特别大，是因为 1000 并发下冷唤醒会被放大：每个新 Agent 首次被调度约 28ms，若这 1000 次冷唤醒串行叠加，理论上是数十秒量级的成本（此处为量级估算，非实测值）。预热把它们全部挪到了启动阶段。

---

## 八、复盘：五条可复用的经验

**1. 先确认你的压测在测什么**
"8333 req/s"听起来很美，但它测的是一个哈希表。**任何性能数字，先问一句：被测对象里有没有网络、有没有序列化、有没有对象创建。**

**2. 主导瓶颈会掩盖一切**
76.9 → 212 的过程中，Agent 创建的 28ms 完全不可见。修完 backlog 才浮现。**每次修完一个瓶颈，重新测量剩余项。**

**3. 端到端 A/B 只能验证主导项，次要项靠分段打点**
`CH4_NO_AGENT=1` 的对照实验给了我错误的结论，是 gate 侧的 `auth=0.52ms agent=25.31ms` 打点给出了真相。

**4. "什么都不做"的函数也有价值**
`handlers.warmup()` 是个空函数，但它消除了 28ms 的冷唤醒。**在 skynet 里，一个服务"被调度过"和"没被调度过"是两个状态。** 类似的还有 `gateserver.openclient(fd)`——不调用它，连接就是死的。

**5. 工具函数的隐式行为是数据失真的重灾区**
`os.clock()` vs `skynet.time()`、`skynet.getenv` vs `os.getenv`、`%d` 遇到浮点——这些都不会报错，只会安静地给你错误的数据。**时间、配置、格式化这三件事，务必显式化。**

---

## 九、已知环境限制（重要）

空闲状态下唤醒一个 skynet 服务约需 **28ms**，这是 **WSL2 虚拟化下的线程调度成本**，不是代码问题。持续负载时该成本消失（实测 ping 稳态 4~5μs）。

**所以：单发请求的延迟数字不代表生产表现，对外请引用并发压测数据。** 这一点在评估任何 skynet 性能时都适用——如果你的测试只有 1 个并发，你测到的可能主要是调度延迟。

---

## 十、代码与运行

```
ch4_login/
├── conf/skynet.conf          # 含 maxclient / gate_backlog / agent_prewarm
├── shared/
│   ├── service.lua           # 统一服务骨架（dispatch + pcall + 自动回包）
│   ├── token.lua             # 128bit 随机串，零哈希
│   ├── utils.lua             # 时间工具（只做减法，不做时钟选择）
│   └── error_code.lua
├── service/
│   ├── center.lua            # 单表 online + token_index + 300s 分桶 + stats
│   └── agent.lua             # 独立服务 + 池化复用 + warmup
├── gateway/
│   ├── main.lua              # 启动编排 + 测试汇总
│   ├── login.lua             # 认证 + Agent 对象池
│   └── gated.lua             # snax.gateserver 封装
├── test/
│   ├── test_login.lua
│   ├── test_center.lua
│   ├── stress_center.lua     # center 单点吞吐基准
│   ├── stress_e2e.lua        # 端到端（这才是可对外报的数字）
│   └── robot.lua             # TCP 机器人客户端
└── old/                      # 原始版本，回归对照基线
```

```bash
wsl -d Ubuntu make -C ch4_login test          # 18 用例，单进程
wsl -d Ubuntu make -C ch4_login stress        # center 单点吞吐
wsl -d Ubuntu make -C ch4_login stress-e2e    # 端到端 1000 并发
wsl -d Ubuntu make -C ch4_login bench         # 两个压测连跑
```

---

> **数据说明**：本文的吞吐/延迟为 WSL2 Ubuntu 上的历史实测记录，测试方法、脚本与断言均可在仓库中复现；具体数值受 CPU、内核版本与虚拟化负载影响会有波动，请以仓库 `ch4_login/log/` 下当次实测日志为准。如果觉得有用，欢迎点赞收藏；如果你在 skynet 优化中遇到过别的"假压测"，欢迎在评论区交流。
