# ch6_ecs — ECS 框架（Lua 低频 + C 高频）

> 《游戏服务器架构》第 6 章的 Skynet 实现。
> 低频逻辑用 Lua ECS，高频逻辑用 C ECS。

---

## 快速开始

```bash
# 编译 C 扩展（luaclib/ecs_high.so）
wsl -d Ubuntu make -C ch6_ecs

# 行为测试 + 性能基准（41 用例）
wsl -d Ubuntu make -C ch6_ecs test

# 只跑基准
wsl -d Ubuntu make -C ch6_ecs bench

# 自定义规模
wsl -d Ubuntu make -C ch6_ecs bench CH6_ENTITY_COUNT=5000 CH6_TICKS=500
```

> ℹ️ `make test` 依赖 `luaclib/ecs_high.so`，Makefile 已声明 `test: $(CSO)`，会自动先编译，
> 正常无需手动 `make`。若绕过 make 直接跑 `skynet conf/skynet.conf`，未编译时才会报
> `cannot load ecs_high.so`。

---

## 目录

| 路径 | 说明 |
|---|---|
| `src/ecs_high.h` / `.c` | **C 高频 ECS**：sparse-set + SoA，Lua 绑定 |
| `shared/ecs_low.lua` | **Lua 低频 ECS**：table 挂接，`each` / `tick` |
| `test/test_ecs.lua` | 行为测试（35 断言） |
| `test/bench_ecs.lua` | 性能基准（6 断言，含跨语言成本测量） |
| `luaclib/` | 编译产物（`make` 生成） |

---

## API

### C ECS（高频）

```lua
local ecs = require "ecs_high"
local w = ecs.new(1024)              -- capacity

w:add(eid, px, py, vx, vy, hp)       -- -> slot | false, err
w:del(eid)                           -- -> bool
w:has(eid)                           -- -> bool
w:get(eid)                           -- -> px, py, hp, slot
w:set_velocity(eid, vx, vy)          -- -> bool
w:damage_all(dmg)
w:update(dt, bound)                  -- 单帧 tick：移动 + 边界反弹 + 回血
w:bench(dt, bound, ticks)            -- -> 总耗时纳秒（C 内部计时）
w:count() / w:capacity()
```

删除用 swap-remove（O(1)），测试 C15 专门验证"删中间元素后其余数据仍正确"。

### Lua ECS（低频）

```lua
local ecs_low = require "shared.ecs_low"
local w  = ecs_low.new()
local e  = w:create()
w:add(e, "position", { x = 0, y = 0 })
w:add(e, "velocity", { x = 1, y = 0 })
w:get(e, "position")
w:remove(e, "velocity")
w:destroy(e)

w:each({ "position", "velocity" }, function(eid, pos, vel) ... end)  -- 通用但慢
w:tick(dt, bound)      -- 专用系统，与 C 版同逻辑
w:bag_total()          -- 低频 CRUD 示例
```

---

## 性能（1000 实体 × 1000 帧，WSL Ubuntu）

| 实现 | 每帧 | 每实体 | 相对 C |
|---|---|---|---|
| Lua 通用 `each()` | 412.65 μs | 413 ns | 333x 慢 |
| Lua 专用 `tick()` | 102.22 μs | 102 ns | 82x 慢 |
| **C `bench()`** | **1.24 μs** | **1.2 ns** | 1x |

**验收标准"C ECS 1000 实体 < 1ms/帧"：实测 0.00124 ms，达标（余量约 800 倍）。**

> 注：以上为历史批次测量值；性能绝对值随 CPU/编译器/环境波动（另一次运行 C 约 1.48μs/帧），
> 量级与结论稳定。以仓库 `ch6_ecs/log/ch6-test/skynet.log` 当次实测为准。

规模梯度（每帧 μs，`ticks=100`）：

| 实体数 | Lua tick | C | 加速比 |
|---|---|---|---|
| 100 | 10.25 | 0.1525 | 67.3x |
| 1000 | 106.96 | 1.2370 | 86.5x |
| 10000 | 1145.59 | 13.6220 | 84.1x |

---

## 两条最重要的设计约束

**1. 每帧一次 Lua→C 调用的开销可以忽略**（−0.041 μs，噪声范围内）
→ 不必为省调用次数做复杂设计。

**2. 但把数据读回 Lua 极其昂贵**：读 1000 个实体 ≈ 52~59 μs，是**一帧的 24~39 倍**
（历史实测 39×，另一批次 24×；绝对值随机器波动，但"读回比算一帧贵 1~2 个数量级"的结论稳定）
→ 整个 system 必须放在 C 里，只把需要广播的增量回传 Lua。
→ 若需全量同步，让 C 直接产出打包好的 buffer，Lua 只做转发。

---

## 编译

```make
CC ?= gcc
OPT ?= -O2          # 可覆盖：make OPT="-O3 -march=native" bench
CFLAGS := $(OPT) -Wall -fPIC -I../skynet/3rd/lua -Isrc
```

> 实测 `-O2` 与 `-O3` 结果完全一致（1.24 ms）——
> 这个循环是**内存访问模式 + 分支预测**受限，不是指令数受限。
> 优化 SoA 遍历要靠数据布局，不是编译器开关。

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 设计取舍、实测数据、跨语言成本
- [`修复.md`](修复.md) — 5 条记录（含"引用语义让断言永远成立"的陷阱）
- 技术博客：[`docs/blog/03-ch6-ecs-双语言ECS设计.md`](../docs/blog/03-ch6-ecs-双语言ECS设计.md)
