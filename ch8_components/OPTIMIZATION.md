# ch8_components 设计取舍

> 依据：design.md Phase 5 —— Agent 启动时动态加载组件，支持组件生命周期管理

---

## 0. 一句话结论

组件化的价值不在"拆文件"，而在**依赖方向**：
组件之间**不互相 require**，全部通过 `ctx`（共享上下文）和 `core:dispatch`（消息路由）通信。
这样每个组件可以独立替换、独立热更、独立测试——这是后面 ch11 跳转、ch12 热更的前提。

---

## 1. 生命周期映射

| design.md 概念 | 本实现 |
|---|---|
| `IAwakeSystem` | 组件的 `init(ctx)` |
| 主动销毁对象的清理 | `skynet.exit()` 前的 `core:shutdown()` |
| 组件式编程 | 一个组件一个模块，导出 `init` / `shutdown` / `handlers` |

---

## 2. 三条硬约定

### 2.1 组件之间不互相 require

跨组件通信走两条路：

- **共享状态**：`ctx.bag` / `ctx.skill` / `ctx.quest`（同一个 Agent 内）
- **消息路由**：`ctx.core:dispatch("bag.remove", 1001, 1)`

例如技能组件学技能要消耗背包里的技能书：

```lua
-- component_skill.lua：不 require component_bag
M.handlers["skill.learn"] = function(ctx, skill_id)
    if (ctx.bag.items[1001] or 0) < 1 then
        return error_code.ERR_INVALID_ARG, "no skill book"
    end
    ctx.core:dispatch("bag.remove", 1001, 1)     -- 走路由
    ctx.skill.list[skill_id] = { level = 1 }
    return error_code.OK, ctx.skill.list[skill_id]
end
```

好处：bag 组件可以整体替换（比如换成走 DB 的实现），skill 完全不用改。

### 2.2 shutdown 严格逆序

后加载的先销毁。`A7.2` 验证：`bag,skill,quest,vip` 加载 → `vip,quest,skill,bag` 销毁。

原因与 C++ / Rust 的析构顺序同理：后构造的对象可能依赖先构造的对象，
逆序销毁才能保证依赖方先释放。

### 2.3 单个组件异常不影响其他组件

- `init` 抛错 → 该组件**完整回滚**（不注册路由、不留在加载顺序里），其余组件照常
- `shutdown` 抛错 → 记录并继续销毁其余组件，最后统一返回错误列表
- `dispatch` 抛错 → 返回 `ERR_INTERNAL`，Agent 存活

`B1` 验证 init 失败后健康组件仍可用、broken 路由未注册；加载顺序（order）的回滚由 `B3.3`
（unload 后 `#list()==0`）间接覆盖。`B4` 验证 shutdown 失败时其余组件仍被销毁并汇总错误。

---

## 3. 运行时动态注入

`component_vip.lua` 不在启动列表里，由外部命令在运行时注入：

```lua
skynet.call(agent, "lua", "load", "vip")     -- 立即 init 并注册路由
skynet.call(agent, "lua", "client", "vip.set", 3)   -- 立刻可用
```

`A5` 验证：注入前 `has("vip") == false`，注入后 handler 立即可用，且顺序追加到末尾。

这是 ch12 热更新的基础：模块可以在 Agent 不重启的情况下替换。

---

## 4. 消息计数与"拆分阈值"

design.md 要求"战斗组件消息量高时拆为独立服务（预留判断阈值）"。

`core:stats(threshold)` 输出每个组件的消息数与建议：

```lua
{
  components = {
    { name = "skill", messages = 5, split_threshold = 3, should_split = true },
    ...
  },
  total_messages = 5,
  threshold = 3,
}
```

`B5` 验证：超过阈值时 `should_split == true`，低于时为 `false`。

> 这只是**判断依据**，不是自动拆分。
> 真正拆服务涉及状态迁移和消息路由重定向，到 ch11（分布式跳转）才具备条件。

---

## 5. 没有做的事

- ❌ **自动拆服务**：只提供阈值判断。自动拆分需要处理跨服务的状态一致性，
  在 ch11 之前不具备条件。
- ❌ **组件间依赖声明**（如 `requires = { "bag" }`）：
  会增加一层依赖解析；当前用"init 里检查 ctx.xxx 是否存在"的轻量方式，
  失败时返回明确错误（`A4.1` 的路径）。
- ❌ **组件热替换的原子性**：当前 `unload` + `load` 两步非原子。
  ch12 会在 queue 保护下做这件事。

---

## 6. 验证

```bash
wsl -d Ubuntu make -C ch8_components test    # 30 断言
```
