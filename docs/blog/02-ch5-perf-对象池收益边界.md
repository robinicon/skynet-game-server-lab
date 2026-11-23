---
title: [Skynet 手记] 对象池是负优化？我用 10 万次分配测出了池化的收益边界
tags: [Skynet, Lua, 游戏服务器, 性能优化, 对象池, GC]
categories: 游戏服务器架构
abbrlink: ch5-perf-pool-boundary
date: 2026-10-27
---

# [Skynet 手记] 对象池是负优化？我用 10 万次分配测出了池化的收益边界

> **摘要**：对象池几乎是游戏服务器性能优化的"标准答案"。但我在 Skynet 上做完一轮基准后发现：给一个 5 字段的小对象套上对象池，性能不是提升而是**下降约 43%**（耗时 46.79ms→82.12ms，即 0.57×）；即便换成更省的快速模式，小对象也只是勉强持平。本文给出完整的测量过程——自研函数级采样 profiler、成本归因方法、三档模式优化，以及最后那张"该不该池化"的决策表。数据可复现（绝对值随环境波动）。
>
> 系列文章：本系列基于《游戏服务器架构》第 4–12 章，用 cloudwu/skynet 逐章重新实现并优化。本文是第 5 章（性能优化与对象池），承接[第 4 章的端到端优化](./01-ch4-login-端到端登录优化实录.md)。

---

## 一、开篇：一个不太对劲的基准结果

按惯例，池化应该是纯收益：少创建对象 → 少分配内存 → 少 GC。我写完了对象池，跑第一轮基准：

```
=== Scenario A: packet (sequential get/use/put) ===
  rounds: 100,000
  -- no-pool:    46.79 ms  created=100,000
  -- pooled :    82.12 ms  created=32
  -- alloc reduction: 99.97%   speedup: 0.57x
```

**分配次数下降了 99.97%，但耗时慢了近一倍。**

如果只看 `created` 这个指标，我几乎要开香槟了——从 10 万次构造降到 32 次。但 0.57x 的 speedup 说明：省下来的构造成本，还不够支付池本身的取还开销。

这个结果值得深挖，因为它指向一个被普遍忽略的事实：**对象池的收益不是"省了分配"，而是"省的分配 − 多出的取还开销"。后者经常被低估。**

---

## 二、第一步：先别优化，确认它是不是热点

`design.md` 的要求写得很清楚：**先 profiling 确认瓶颈，再池化**。所以第一步是确认"对象创建"真的是热点。

### 2.1 skynet 内置 profiler 只有服务级

skynet 内置了 profile（`profile = 1` 默认开启），但只暴露**服务级**的累计 CPU：

```lua
skynet.stat("cpu")      -- 该服务累计消耗的 CPU 微秒
skynet.stat("message")  -- 处理的消息数
```

这能回答"哪个服务最忙"，但回答不了"服务里哪个函数最忙"。要做函数级归因，得自己动手。

### 2.2 自研采样 profiler

原理是 `debug.sethook`：每执行 N 条 VM 指令触发一次 hook，在 hook 里记录当前函数。

```lua
local samples = {}

local function hook()
    local info = debug.getinfo(2, "nSf")
    if not info then return end
    local f = info.func
    if not f then return end
    local e = samples[f]
    if e then
        e.count = e.count + 1
    else
        samples[f] = {
            name   = info.name or "?",
            source = info.short_src or "?",
            line   = info.linedefined or 0,
            count  = 1,
        }
    end
end

function M.start(interval)
    samples = {}
    debug.sethook(hook, "", interval or 1000)
end
```

> ⚠️ **一个必须知道的坑**：Lua 5.2+ 的 debug hook 是 **per-coroutine** 的，
> `debug.sethook` 只影响当前协程。负载代码一旦 yield 切走，采样就停了。
> 所以这个 profiler 只适用于**不 yield 的同步代码块**（基准循环、纯计算）。
> 要 profile 含 `skynet.call` 的异步流程，只能在每个协程内分别 start/stop，
> 或退回服务级的 `skynet.stat("cpu")`。

### 2.3 采样结果

对非池化的 packet 负载采样（20,000 轮）：

```
--- profiler: 530 samples, cpu 0.008s ---
PCT%   SAMPLES  FUNCTION
42.64  226      use (./shared/workload.lua:34)
30.57  162      anonymous (./test/bench_pool.lua:160)
26.79  142      factory (./shared/workload.lua:17)
```

`factory`（对象构造）占 **26.79%** ——确实是热点，值得优化。热点确认完毕，可以动手了。

---

## 三、成本归因：把"池开销"单独拎出来测

0.57x 的结果摆在面前，下一步不是猜，是**把开销拆开**。我加了一个纯微基准：只做 `get` + `put`，不做任何业务操作，直接和"裸构造"对比。

```
=== Scenario E: overhead breakdown (get+put vs factory, no use) ===
  -- factory()        :    15.92 ms  ( 159.2 ns/op)
  -- get+put / strict :    23.53 ms  ( 235.3 ns/op)  overhead 1.48x
  -- get+put / fast   :    16.15 ms  ( 161.5 ns/op)  overhead 1.01x
  -- get+put / bare   :    13.15 ms  ( 131.5 ns/op)  overhead 0.83x
```

这组数字把问题彻底说清楚了：

- **strict 模式一次取还要 235 ns，而直接构造一个对象只要 159 ns** —— 池比构造还贵
- **bare 模式只要 131 ns，比构造还便宜 17%** —— 说明池化**理论上**有收益空间

两者之间差了 104 ns，全部来自"检测 + 统计"。那么这 104 ns 具体是什么？

| 开销项 | 说明 |
|---|---|
| `owned` 弱表查找 | foreign / double-free 检测，2 次哈希查找 |
| `pcall(reset, obj)` | pcall 本身有固定开销 |
| 统计计数 | 4~8 次 table 字段读写 |
| table 字段访问 | `self.n_free` / `self.stat.*` 每次都是哈希查找 |

最后一项是我最初实现的性能陷阱：状态全放在 table 字段里，每次访问一次哈希。

---

## 四、优化：两件事把 235 ns 降到 131 ns

### 4.1 热路径状态从 table 字段改成闭包 upvalue

Lua 里访问 `self.n_free` 是一次哈希查找，而访问 upvalue 是**寄存器访问**。把热路径的状态挪进闭包：

```lua
-- 优化前
api.get = function(_)
    if self.n_free > 0 then
        local obj = self.free[self.n_free]
        self.free[self.n_free] = nil
        self.n_free = self.n_free - 1
        self.stat.reused = self.stat.reused + 1
        ...
    end
end

-- 优化后
local free, n_free = {}, 0
local created, reused, borrowed, peak = 0, 0, 0, 0

api.get = function(_)
    if n_free > 0 then
        local obj = free[n_free]
        free[n_free] = nil
        n_free = n_free - 1
        reused = reused + 1
        ...
    end
end
```

这是 Lua 中把"表驱动"改成"闭包驱动"的经典优化，代价是状态不再集中在一个对象里——
所以要把所有对外方法（`get`/`put`/`prewarm`/`clear`/`stats`）都做成访问同一批 upvalue 的闭包。

### 4.2 按 mode 分档，用闭包特化消除运行时分支

不是所有场景都需要完整检测。分成三档，在 `new` 时**直接生成不同的闭包**，热路径上没有 `if mode ==` 判断：

| mode | 检测 | 统计 | 开销 | 定位 |
|---|---|---|---|---|
| `strict` | foreign / double-free / reset 失败 | 全量 | 1.48x | 开发、测试 |
| `fast` | 无 | 核心计数 | 1.01x | **生产推荐** |
| `bare` | 无 | 无 | 0.83x | 极限性能，无观测性 |

```lua
if mode == "strict" then
    api.get = function(_) ... end      -- 含 owned 检测
    api.put = function(_, obj) ... end -- 含 pcall(reset)
elseif mode == "fast" then
    api.get = function(_) ... end      -- 无检测，保留计数
    api.put = function(_, obj) ... end -- reset 直接调用
else
    api.get = function(_) ... end      -- 纯 free-list
    api.put = function(_, obj) ... end
end
```

---

## 五、优化后的完整数据

100,000 轮，WSL Ubuntu：

| 场景 | 对象特征 | no-pool | strict | fast | bare | heap_peak (no→pool) |
|---|---|---|---|---|---|---|
| A | packet（5 标量字段） | 42.12 ms | 0.81x | 0.95x | **1.02x** | 59.2 → 68.6 KB |
| B | aoi_entity（嵌套数组，hold=64） | 63.86 ms | **1.31x** | — | — | 106.1 → 123.2 KB |
| C | heavy（变长，每次填 200 项） | 27.51 ms | 0.93x | — | — | 123.0 → 131.5 KB |
| D | damage_event（嵌套数组） | 86.97 ms | **1.15x** | — | — | 134.2 → **78.8 KB** |

分配次数：

| 场景 | no-pool | pooled | 下降 |
|---|---|---|---|
| A | 100,000 | 32 | 99.97% |
| B | 100,000 | 64 | 99.94% |
| C | 10,000 | 32 | 99.68% |
| D | 100,000 | 32 | 99.97% |

`design.md` 的验收标准"池化后对象分配次数下降 >50%"全部达标。但**耗时只有两个场景真正变快了**。

### 为什么 B / D 快，A 不快？

关键不在"字段多少"，而在**构造时的分配次数**：

| 对象 | factory 的分配次数 | 池化收益 |
|---|---|---|
| packet（5 个标量） | **1 次**（一个 table） | 0.81x ❌ |
| aoi_entity（含 `neighbors` 嵌套表） | **2 次** | 1.31x ✅ |
| damage_event（含 `flags` 嵌套表） | **2 次** | 1.15x ✅ |

嵌套一次就多一次内存分配，构造成本翻倍，池化的净收益随之转正。

### 场景 C：一个真正的负优化

`heavy` 对象的 `factory` 只建一个空壳（1 个字段，极便宜），但每次使用会往 `items` 里塞 200 个元素。`reset` 必须逐个清空：

```lua
M.heavy = {
    factory = function() return { items = {} } end,     -- 空壳，极便宜
    reset = function(o)
        local n = o.items
        for i = #n, 1, -1 do n[i] = nil end             -- O(已用长度)
    end,
    use = function(o, i)
        for k = 1, 200 do o.items[k] = i + k end
    end,
}
```

结果 0.93x。而且**这个成本无法优化掉**——清空是必须的，留着 stale 引用会让整个数组连带泄漏。

这里暴露了池化中最容易被低估的一项：**reset 的成本通常与"上次使用的规模"成正比，而构造成本是固定的。** 所以变长对象天然不适合池化。

---

## 六、过程中那个致命 bug：`:` 调用把 self 当成了第一个参数

优化过程中我踩了一个特别阴险的坑，值得单独讲。

为了做闭包特化，我把 `get` / `put` 从 metatable 方法改成闭包：

```lua
api.put = function(obj)          -- 期望 obj = 业务对象
    local st = owned[obj]
    ...
end
```

调用方用的是方法语法 `p:put(o)`。Lua 会把它展开成 `p.put(p, o)` ——
**`self`（池对象本身）成了第一个实参**，闭包里的 `obj` 拿到的根本不是业务对象，而是池的 api table。

后果链：

```
owned[api_table] == nil
        ↓
判为 foreign object，put 返回 false
        ↓
对象从未归还 → 池永远为空 → 每次 get 都走 factory
        ↓
created == 循环次数（100,000），池化收益归零，还多了一次失败的 put
```

**最危险的地方是：它不报错、不崩溃。** 池只是静默退化成了"每次新建"。如果只看 CPU 耗时，很容易得出"池化没收益"的错误结论——实际上是实现错了。

同一个坑还有第二处：`M.new` 内部调用 `api.prewarm(opts.prewarm)` 用的是 `.` 语法，改签名后 `prewarm` 参数跑到了 `self` 的位置，预热数量被静默吞成 0。

**修复**：所有闭包统一加 `self` 首参，与 `:` 调用约定对齐：

```lua
api.get      = function(_) ... end
api.put      = function(_, obj) ... end
api.prewarm  = function(_, n) ... end
api.stats    = function(_) ... end
-- 内部调用也要改：api:prewarm(opts.prewarm)
```

> **教训**：`created`（真实构造次数）比耗时更适合做池化的首要验收指标。
> 耗时会被各种因素掩盖，**但构造次数不会说谎**。
> 这也是我把 `alloc reduction` 而不是 speedup 作为第一断言的原因。

---

## 七、GC 视角：一个容易忽略的隐藏收益

场景 D 的数字里有一列值得单独看：

```
-- no-pool:    86.97 ms   heap_peak=134.2 KB
-- pooled :    75.74 ms   heap_peak= 78.8 KB     ← 峰值降了 41%
```

CPU 只快了 15%，但**堆峰值降了 41%**。

池化的本质是：把"大量短命对象"变成"少量长期存活对象"。短命对象会在新生代反复触发 GC，堆峰值随之剧烈波动；长期存活对象进入老年代，GC 的扫描频率和晋升压力都下降。

**在 GC 停顿敏感的服务里（比如战斗帧同步），这个收益可能比 CPU 更重要。** 所以评估池化时不要只看耗时，heap 峰值同样值得测——我的基准里每 1000 轮采样一次 `collectgarbage("count")` 取最大值。

---

## 八、结论：该不该池化

| 对象类型 | 建议 | 依据 |
|---|---|---|
| 含嵌套分配（≥2 次 table 分配） | ✅ 池化 | B 1.31x、D 1.15x |
| 含 C 资源 / 服务句柄 / 大数组 | ✅ 池化 | 构造成本远高于取还成本 |
| 纯标量小对象（≤5 字段） | ⚠️ 只有 bare 才勉强持平 | A：strict 0.81x、bare 1.02x |
| 变长对象（reset 成本 ∝ 使用规模） | ❌ 不池化 | C 0.93x |
| 低频对象（账号 / 角色 / 配置） | ❌ 不池化 | 本来就常驻，不存在"反复创建" |

判定公式：

```
池化收益 = (构造成本 − 取用成本 − 归还成本) × 复用次数
```

其中**归还成本含 reset**，而 reset 通常与上次使用规模成正比——这是最容易被低估的一项。

### 复用本篇代码的 checklist

1. 先用 profiler 确认构造是热点（本文是 26.79%）
2. 测 `factory()` 的单次成本（ns/op）
3. 测池的 `get+put` 单次成本
4. 若 `get+put > factory`，先换 `fast` / `bare` 模式再测
5. 仍然倒挂 → 这个对象不该池化，别硬上
6. 池化后同时看 **耗时** 和 **heap 峰值** 两个指标

---

## 九、复盘：六条可复用的经验

**1. 用"构造次数"当首要验收指标，别用耗时**
`created` 从 10 万降到 32 不会说谎，而 0.57x 的 speedup 会被各种因素掩盖。第六节那个 `:` 调用 bug 让池静默退化成"每次新建"，耗时看起来只是"没收益"，是 `created==100000` 暴露了真相。

**2. 池化收益是一道减法，归还成本最容易被低估**
`收益 = (构造成本 − 取用成本 − 归还成本) × 复用次数`，而归还成本含 `reset`。场景 C 的 `reset` 要清 200 项，与上次使用规模成正比，结果 0.93x——变长对象天生不适合池化。

**3. 先 profiling 确认热点，再动手**
采样显示 `factory` 只占 26.79%，才值得优化。如果构造本就不是热点，池化再多也是在优化无关紧要的路径。

**4. 热路径状态放闭包 upvalue，不放 table 字段**
`self.n_free` 是哈希查找，upvalue 是寄存器访问。这一处改动把 get+put 从 235 ns 降到 131 ns。

**5. 用闭包特化消除运行时分支**
按 mode 在 `new` 时直接生成不同闭包，热路径上没有 `if mode ==`。strict/fast/bare 三档覆盖开发、生产、极限场景。

**6. 别只看 CPU，heap 峰值也是收益**
场景 D 的 CPU 只快 15%，但堆峰值从 134.2 KB 降到 78.8 KB（−41%）。在 GC 停顿敏感的服务里，这个收益可能比 CPU 更重要。

---

## 十、已知环境限制（重要）

- 本文所有 speedup / 耗时 / 堆峰值为 **WSL2 Ubuntu 上的历史实测记录**，基准脚本与断言均可在仓库中复现；绝对值随 CPU、内核版本、Lua/编译器版本波动，请以 `ch5_perf/log/` 下当次实测日志为准。
- **采样 profiler 是 per-coroutine 的**：`debug.sethook` 只影响当前协程，负载一旦 yield 切走采样就停。它只适用于不 yield 的同步代码块（基准循环、纯计算）；要 profile 含 `skynet.call` 的异步流程只能退回服务级 `skynet.stat("cpu")`。
- **微基准噪声不可忽略**：strict/fast/bare 之间的差值可能落在测量噪声里，结论要看量级和趋势，不要纠结单次小数点。

---

## 十一、代码与运行

```
ch5_perf/
├── shared/
│   ├── pool.lua       # 通用对象池（三档模式，闭包 upvalue 热路径）
│   ├── profiler.lua   # 采样式函数级 profiler
│   └── workload.lua   # 业务对象定义（含 heavy 反例）
├── service/objservice.lua
├── test/
│   ├── test_pool.lua  # 59 断言
│   └── bench_pool.lua # 场景 A–E + profiling
└── conf/ runtime.lua main.lua Makefile
```

```bash
wsl -d Ubuntu make -C ch5_perf test    # 59 用例
wsl -d Ubuntu make -C ch5_perf bench   # 9 用例 + 基准报告
```

---

> **数据说明**：本文的耗时/speedup/堆峰值为历史实测记录，基准脚本与断言均可在仓库中复现；具体数值随 CPU 与环境波动，请以仓库 `ch5_perf/log/` 下当次实测日志为准。如果你在项目中用过对象池，欢迎在评论区分享你测到的 speedup——特别是负优化的经历。
