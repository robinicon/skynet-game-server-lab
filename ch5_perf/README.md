# ch5_perf — 性能优化与对象池

> 《游戏服务器架构》第 5 章的 Skynet 实现。
> 核心产出：一个通用业务对象池 + 一套"该不该池化"的量化决策依据。

---

## 快速开始

```bash
# 对象池正确性测试（18 组用例 / 59 个断言）
wsl -d Ubuntu make -C ch5_perf test

# 池化 vs 非池化基准 + 函数级 profiling（9 用例）
wsl -d Ubuntu make -C ch5_perf bench

# 两者都跑
wsl -d Ubuntu make -C ch5_perf all

# 自定义规模
wsl -d Ubuntu make -C ch5_perf bench CH5_BENCH_ROUNDS=200000 CH5_BENCH_HOLD=128
```

---

## 目录

| 路径 | 说明 |
|---|---|
| `shared/pool.lua` | **通用业务对象池**（三档模式，闭包 upvalue 热路径） |
| `shared/profiler.lua` | 采样式 CPU profiler（`debug.sethook`，函数级热点） |
| `shared/workload.lua` | 业务对象定义：packet / aoi_entity / damage_event / heavy（反例） |
| `service/objservice.lua` | 业务服务，演示服务级 `skynet.stat("cpu")` 对照 |
| `test/test_pool.lua` | 正确性测试（59 断言，18 组） |
| `test/bench_pool.lua` | 基准 A–E + profiling |
| `main.lua` / `runtime.lua` / `conf/skynet.conf` | 启动编排与配置（与 ch4_login 同构） |

---

## API

```lua
local pool = require "shared.pool"

local p = pool.new({
    name    = "packet",        -- 池名（统计用）
    mode    = "fast",          -- "strict" | "fast" | "bare"
    factory = function() return { cmd = 0, uid = 0 } end,   -- 必填
    reset   = function(o) o.cmd = 0; o.uid = 0 end,         -- 强烈建议提供
    max     = 1024,            -- 池上限，超限后 put 直接丢弃（不阻塞）
    prewarm = 32,              -- 预热数量
})

local o = p:get()      -- 取（池空则 factory 新建，永不阻塞）
p:put(o)               -- 还（strict 返回 bool, errcode）
p:prewarm(n)           -- 预热
p:clear()              -- 清空
p:stats()              -- 统计快照
p:reuse_rate()         -- reused / (reused + created)
p:size()               -- 当前空闲数（热路径读取）
```

### 三档模式

| mode | 检测 | 统计 | 开销（vs 直接构造） | 用途 |
|---|---|---|---|---|
| `strict` | foreign / double-free / reset 失败 | 全量 | 1.48x | 开发、测试 |
| `fast` | 无 | 核心计数 | 1.01x | **生产推荐** |
| `bare` | 无 | 无 | 0.83x | 极限性能，无观测性 |

---

## 该不该池化（决策表）

| 对象类型 | 建议 | 实测依据 |
|---|---|---|
| 含嵌套分配（≥2 次 table 分配） | ✅ 池化 | aoi_entity **1.31x**、damage_event **1.15x** |
| 含 C 资源 / 服务句柄 / 大数组 | ✅ 池化 | 构造成本远高于取还成本 |
| 纯标量小对象（≤5 字段） | ⚠️ 仅 bare 勉强持平 | packet：strict **0.81x**、bare 1.02x |
| 变长对象（reset 成本 ∝ 使用规模） | ❌ 不池化 | heavy **0.93x** |
| 低频对象（账号/角色/配置） | ❌ 不池化 | 本来就常驻，无"反复创建" |

**判定公式**

```
池化收益 = (构造成本 − 取用成本 − 归还成本) × 复用次数
```

归还成本含 reset，而 **reset 通常与"上次使用规模"成正比**——最容易被低估的一项。

---

## 性能数据（100,000 轮，WSL Ubuntu）

| 场景 | 对象特征 | no-pool | strict | fast | bare | heap_peak (no→pool) |
|---|---|---|---|---|---|---|
| A | packet（5 标量） | 42.12 ms | 0.81x | 0.95x | 1.02x | 59.2 → 68.6 KB |
| B | aoi_entity（嵌套，hold=64） | 63.86 ms | **1.31x** | — | — | 106.1 → 123.2 KB |
| C | heavy（变长，填 200 项） | 27.51 ms | 0.93x | — | — | 123.0 → 131.5 KB |
| D | damage_event（嵌套） | 86.97 ms | **1.15x** | — | — | 134.2 → **78.8 KB** |

分配次数（`created`）下降 **99.68% ~ 99.97%**，满足 design.md 的 ">50%" 验收标准。

成本归因（纯 get+put，不含业务操作）：

```
factory()        :  15.92 ms  (159.2 ns/op)
get+put / strict :  23.53 ms  (235.3 ns/op)   overhead 1.48x
get+put / fast   :  16.15 ms  (161.5 ns/op)   overhead 1.01x
get+put / bare   :  13.15 ms  (131.5 ns/op)   overhead 0.83x
```

> 场景 D 的 GC 峰值从 134.2 KB 降到 78.8 KB（−41%）。
> **即使 CPU 时间没省下来，池化对 GC 停顿敏感的服务仍有价值。**

---

## 关于 profiler

skynet 内置 profile 只提供**服务级**累计 CPU（`skynet.stat("cpu")`）。
本项目的 `shared/profiler.lua` 补齐**函数级**：

```lua
profiler.start(1000)     -- 每 1000 条 VM 指令采样一次
-- ... 同步负载 ...
local r = profiler.stop()
profiler.report(r, 8)    -- 打印 Top 8 热点
```

⚠️ **适用边界**：Lua 5.2+ 的 debug hook 是 **per-coroutine** 的，
`debug.sethook` 只影响当前协程。**含 yield 的代码采样不到**，
只能用于不 yield 的同步代码块（基准循环、纯计算）。
要 profile 异步流程，请在每个协程内分别 start/stop，或改用 `skynet.stat("cpu")`。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CH5_TEST_TARGET` | — | 测试目标：`test_pool` / `bench_pool` |
| `CH5_BENCH_ROUNDS` | 100000 | 基准循环次数 |
| `CH5_BENCH_HOLD` | 64 | 场景 B 同时持有对象数 |

> 用 `os.getenv` 读取。**`skynet.getenv` 读的是 skynet 配置环境，读不到进程环境变量。**

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 优化过程、成本归因、决策依据
- [`修复.md`](修复.md) — 5 条缺陷记录（含"闭包特化后 `:` 调用传 self"这个致命坑）
- 技术博客：[`docs/blog/02-ch5-perf-对象池收益边界.md`](../docs/blog/02-ch5-perf-对象池收益边界.md)
