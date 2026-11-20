# ch5_perf 优化记录：对象池的收益边界

> 优化对象：`shared/pool.lua`（通用业务对象池）
> 依据：design.md Phase 2 —— **先 profiling 确认瓶颈，再池化**

---

## 0. 一句话结论

**池化不是万能的。** 实测：含嵌套分配的对象池化有 1.15~1.31x 收益；
纯标量小对象池化是 **0.81x 负优化**；变长对象（reset 成本随规模增长）是 **0.93x 负优化**。
决定收益的不是"字段多少"，而是 **构造时的分配次数** 与 **reset 成本**。

---

## 1. Baseline：先确认对象创建是不是热点

用自研采样 profiler（`shared/profiler.lua`，基于 `debug.sethook`）对非池化负载采样：

```
--- profiler: 530 samples, cpu 0.008s ---
PCT%   SAMPLES  FUNCTION
42.64  226      use (./shared/workload.lua:34)
30.57  162      anonymous (./test/bench_pool.lua:160)
26.79  142      factory (./shared/workload.lua:17)
```

`factory`（对象构造）占 **26.79%** ——确实是热点，值得优化。
（另一个 30.57% 的 anonymous 是 bench 的循环闭包与临时变量，不是业务成本。）

> 注：skynet 内置 profile 只有服务级 `skynet.stat("cpu")`，拿不到函数级热点，
> 所以补了这个采样式 profiler。它只适用于**不 yield 的同步代码块**
> （`debug.sethook` 在 Lua 5.2+ 是 per-coroutine 的，yield 后采样中断）。

---

## 2. 第一次实现：strict 模式（完整检测 + 完整统计）

第一版池提供完整的安全保障：foreign object 检测、double-free 检测、reset 失败保护、
齐全的统计计数。用 metatable + table 字段存状态。

**结果（场景 A，packet，100k 轮）**：

```
-- no-pool:    46.79 ms  created=100,000
-- pooled :    82.12 ms  created=32        speedup: 0.57x
```

分配次数下降 99.97%（达标），但**耗时慢了近一倍**。

> 注：此处 46.79ms 是首版 strict 基准；后文场景表里的 42.12ms 是调优参数后的另一次基线，
> 两者不是同一次测量，不可直接相减。以 `ch5_perf/log/` 当次日志为准。

---

## 3. 成本归因：把开销拆开看

新增场景 E（纯 get/put，不含 use），直接对比"池开销"与"构造开销"：

```
-- factory()        :    15.92 ms  ( 159.2 ns/op)
-- get+put / strict :    23.53 ms  ( 235.3 ns/op)  overhead 1.48x
-- get+put / fast   :    16.15 ms  ( 161.5 ns/op)  overhead 1.01x
-- get+put / bare   :    13.15 ms  ( 131.5 ns/op)  overhead 0.83x
```

关键数字：**strict 模式一次 get+put 要 235ns，而构造一个新对象只要 159ns。**
对小对象，池的取还开销比直接构造还贵——负优化不可避免。

注意 `bare` 是 **0.83x**：纯 free-list 的 get+put 比构造更快。
说明池化在理论上有收益空间，只是被"检测 + 统计"吃掉了。

---

## 4. 优化动作

### 4.1 热路径状态从 table 字段改为闭包 upvalue

```lua
-- 优化前：每次访问是一次哈希查找
api.get = function(_)
    if self.n_free > 0 then ... self.stat.reused = self.stat.reused + 1 ...
end

-- 优化后：upvalue 是 Lua 寄存器访问
local free, n_free = {}, 0
local created, reused, borrowed, peak = 0, 0, 0, 0
api.get = function(_)
    if n_free > 0 then
        local obj = free[n_free]; free[n_free] = nil; n_free = n_free - 1
        reused = reused + 1
        ...
    end
end
```

### 4.2 按 `mode` 分档，用闭包特化消除运行时分支

| mode | 检测 | 统计 | 定位 |
|---|---|---|---|
| `strict` | foreign / double-free / reset 失败 | 全量 | 开发、测试 |
| `fast` | 无 | created/reused/borrowed/peak/discarded | **生产推荐** |
| `bare` | 无 | 无 | 极限性能，无观测性 |

在 `new` 时按 mode 直接生成不同的闭包，热路径上没有 `if mode ==` 的判断。

### 4.3 `reset` 从 `pcall` 改为直接调用（fast / bare）

strict 保留 `pcall`（reset 抛错时拒绝入库，避免脏对象污染池）；
fast / bare 直接调用，文档约定 reset 不得抛错。

---

## 5. 优化后结果（100,000 轮，WSL Ubuntu）

| 场景 | 对象特征 | no-pool | strict | fast | bare | heap_peak (no→pool) |
|---|---|---|---|---|---|---|
| A | packet（5 标量） | 42.12 ms | 0.81x | 0.95x | **1.02x** | 59.2 → 68.6 KB |
| B | aoi_entity（嵌套数组，hold=64） | 63.86 ms | **1.31x** | — | — | 106.1 → 123.2 KB |
| C | heavy（变长，每次填 200 项） | 27.51 ms | 0.93x | — | — | 123.0 → 131.5 KB |
| D | damage_event（嵌套数组） | 86.97 ms | **1.15x** | — | — | 134.2 → **78.8 KB** |

分配次数（`created`）：

| 场景 | no-pool | pooled | 下降 |
|---|---|---|---|
| A | 100,000 | 32 | 99.97% |
| B | 100,000 | 64 | 99.94% |
| C | 10,000 | 32 | 99.68% |
| D | 100,000 | 32 | 99.97% |

design.md 验收标准"对象分配次数下降 >50%" **全部达标**。

---

## 6. 结论：该不该池化

| 对象类型 | 建议 | 依据 |
|---|---|---|
| 含嵌套分配（≥2 次 table 分配） | ✅ 池化 | 场景 B 1.31x、D 1.15x |
| 含 C 资源 / 服务句柄 / 大数组 | ✅ 池化 | 构造成本远高于取还成本 |
| 纯标量小对象（5 字段以内） | ⚠️ 只有 bare 才勉强持平 | 场景 A：strict 0.81x、bare 1.02x |
| 变长对象（reset 成本 ∝ 使用规模） | ❌ 不池化 | 场景 C 0.93x |
| 低频对象（账号、角色、配置） | ❌ 不池化 | 本来就常驻，不存在"反复创建" |

**判定公式**：

```
池化收益 = 构造成本 × 复用次数 − (取用成本 + 归还成本) × 复用次数
```

其中归还成本包含 reset，而 **reset 的成本通常与"上次使用的规模"成正比**——
这是最容易被低估的一项。

**GC 视角的额外收益**：场景 D 的 heap_peak 从 134.2 KB 降到 78.8 KB（−41%）。
即使 CPU 时间没有明显节省，池化也能显著降低 GC 峰值压力——
在 GC 停顿敏感的服务里，这个收益可能比 CPU 更重要。

---

## 7. 没有做的优化（及原因）

- ❌ **给 strict 模式继续提速**：strict 的定位就是"开发期安全网"。
  生产用 fast（1.01x 开销）已经与直接构造持平，再优化要牺牲检测能力。
- ❌ **自动选择 mode**：运行期自动判断是否池化需要采样成本，得不偿失。
  改为在基准里给出决策表（§6），由人来判断。
- ❌ **对象池按类型自动注册**：会增加一张全局表的查找。使用者显式建池更清晰。

---

## 8. 验证

```bash
wsl -d Ubuntu make -C ch5_perf test     # 18 组 / 59 断言（正确性）
wsl -d Ubuntu make -C ch5_perf bench    # 9 条基准断言（基准 + profiling）
```
