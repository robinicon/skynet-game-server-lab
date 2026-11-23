# ch8_components — 组件式编程

> 《游戏服务器架构》第 8 章的 Skynet 实现。
> Agent 启动时动态加载组件，支持运行时注入与逆序销毁。

---

## 快速开始

```bash
wsl -d Ubuntu make -C ch8_components test    # 30 断言
```

---

## 目录

| 路径 | 说明 |
|---|---|
| `shared/agent_core.lua` | **核心**：组件注册/卸载、消息路由、逆序 shutdown、消息计数 |
| `shared/component_bag.lua` | 背包组件 |
| `shared/component_skill.lua` | 技能组件（跨组件通信示例） |
| `shared/component_quest.lua` | 任务组件（完成时给背包发奖） |
| `shared/component_vip.lua` | VIP 组件（**运行时动态注入**示例） |
| `service/agent.lua` | 组件式 Agent 服务 |
| `test/test_components.lua` | 30 断言（A 组集成 / B 组单元） |

---

## 组件契约

```lua
local M = {}

M.name = "xxx"

function M.init(ctx)      -- 映射 IAwakeSystem，Agent 启动时调用
    ctx.xxx = {}
    return true
end

function M.shutdown(ctx)  -- Agent 销毁时调用（逆序）
    ctx.xxx = nil
    return true
end

M.handlers = {}           -- 消息路由表
M.handlers["xxx.do"] = function(ctx, a, b)
    return error_code.OK, result
end

return M
```

> ⚠️ Lua 语法：必须写成 `M.handlers["xxx.do"] = function(...)`，
> **不能**写 `function M.handlers["xxx.do"](...)` —— 后者是非法语法
> （function 定义的名字只支持点号分隔的标识符）。
> 但 `M.handlers["xxx.do"](ctx)` 这种**调用**是合法的。

---

## 三条硬约定

**1. 组件之间不互相 require**
跨组件通信走 `ctx`（共享状态）或 `ctx.core:dispatch(...)`（消息路由）。
好处：任意组件可独立替换/热更，不影响其他组件。

**2. shutdown 严格逆序**
`bag,skill,quest,vip` 加载 → `vip,quest,skill,bag` 销毁。
与 C++ / Rust 的析构顺序同理：后构造的可能依赖先构造的。

**3. 单个组件异常不影响其他**
- init 抛错 → 该组件**完整回滚**（不注册路由、不留加载顺序），其余照常
- shutdown 抛错 → 记录并继续，最后统一返回错误列表
- dispatch 抛错 → 返回 `ERR_INTERNAL`，Agent 存活

---

## API

```lua
-- Agent 服务
skynet.call(agent, "lua", "init", uid, { bag_capacity = 20 })  -- -> 已加载组件列表
skynet.call(agent, "lua", "client", "bag.add", 101, 5)         -- -> code, ...
skynet.call(agent, "lua", "load", "vip")                       -- 运行时注入
skynet.call(agent, "lua", "unload", "vip")
skynet.call(agent, "lua", "list")                              -- 加载顺序
skynet.call(agent, "lua", "events")                            -- 生命周期事件
skynet.call(agent, "lua", "stats", threshold)                  -- 消息计数 + 拆分建议
skynet.call(agent, "lua", "exit")                              -- 逆序 shutdown

-- agent_core（可独立使用）
local core = core_mod.new({ ctx = ctx, on_error = fn })
core:load(name, mod) / core:unload(name) / core:dispatch(cmd, ...)
core:shutdown() / core:list() / core:has(name) / core:event_log()
```

---

## 消息计数与拆分阈值

`design.md`：战斗组件消息量高时拆为独立服务。本实现提供**判断依据**：

```lua
core:stats(1000)
-- { components = { { name="skill", messages=5, split_threshold=1000, should_split=false } },
--   total_messages = 5, threshold = 1000 }
```

阈值可用 `CH8_SPLIT_THRESHOLD` 覆盖。这只是判断，不自动拆分——
自动拆服务涉及状态迁移，到 ch11（分布式跳转）才具备条件。

---

## 测试覆盖

| 组 | 内容 |
|---|---|
| A1 | 启动加载 3 个组件，init 顺序 = 加载顺序 |
| A2 | 消息路由 + 多返回值 |
| A3 | 跨组件：任务完成 → 背包发奖 |
| A4 | 跨组件：学技能 → 扣背包技能书 |
| A5 | **运行时注入** vip，立即可用 |
| A6 | 未知 cmd 被拒绝 |
| A7 | **逆序** shutdown |
| B1 | init 失败的隔离与回滚 |
| B2 | 重复加载被拒 |
| B3 | 卸载后路由摘除 |
| B4 | shutdown 抛错不影响其他组件 |
| B5 | 消息计数与拆分阈值 |

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 设计取舍与三条硬约定
- [`修复.md`](修复.md) — 3 条记录（含 Lua 函数定义语法坑、init 失败未回滚）
- 技术博客：[`docs/blog/05-ch8-components-组件式Agent.md`](../docs/blog/05-ch8-components-组件式Agent.md)
