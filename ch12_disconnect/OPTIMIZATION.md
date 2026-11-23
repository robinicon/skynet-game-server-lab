# ch12_disconnect 优化与设计实录

本文记录「断线延迟销毁」与「运行中热更新」两个机制的设计与实测数据。目标不是堆功能，而是
把两件生产里最怕的事——**玩家掉线瞬间丢状态**和**改一行逻辑就要重启全服**——做成平滑、
向前兼容。（注：本期未实现热更失败回滚/灰度，属已知局限，见文末「局限」一节。）

---

## 0. 测量方法论

ch12 的正确性不靠墙钟，靠**三个不变量**：

1. **重连不变量**：断线 → offline（不 exit）；重连 → 原 Agent 原地复活、fd 换新、状态无损。
2. **超时不变量**：超时未重连 → Agent 退出且状态已落盘（db_stub 能查到）。
3. **热更不变量**：运行中 Agent 重载到新逻辑版本，旧状态继续可处理、不崩；新字段向前兼容。

每个用例都做**双向对齐**：断线前快照 vs 断线后 meta；存盘内容 vs 内存最后状态；热更前后
`logic.VERSION` 与 `state` 字段。

---

## 1. 断线延迟销毁：为什么不直接 exit

线上「掉线」绝大部分是瞬断（WiFi 抖动、切后台、网关闪断）。如果一检测到断线就 `skynet.exit()`
销毁 Agent，玩家每次抖一下就被踢回登录——体验灾难，也对数据库/登录服造成尖峰。

正确做法：**断线只挂 `offline` 标记 + 起一个超时定时器**，给重连留窗口：

```lua
function CMD.on_disconnect()
    online = false
    offline_timer = skynet.timeout(OFFLINE_TIMEOUT_CS, function()
        CMD.save_and_exit()
    end)
end
```

实测 T1/T2（默认超时 100cs = 1s）：

```
[PASS] T1.1   断开后 offline          -- 没 exit
[PASS] T1.2   断开后 agent 仍存活
[PASS] T2.1   重连后 online
[PASS] T2.2   重连后 agent 仍存活
[PASS] T2.3   fd 已更新为新 fd(2999)  -- 换 fd 不换 Agent
```

T2.3 是关键：**重连是"换 fd 不换 Agent"**——新 fd 绑回原来的 Agent、取消定时器、恢复
`online`。玩家状态始终在那一个 Agent 里，重连零迁移、零加载，这是断线延迟销毁相比「销毁重建」
最大的体验优势。

---

## 2. 超时退出：先存盘再走

窗口期过了还没重连，说明玩家真走了，该释放资源了。但**退出前必须存盘**，否则内存状态丢：

```lua
function CMD.save_and_exit()
    local db = skynet.uniqueservice("db_stub")
    pcall(skynet.call, db, "lua", "save", uid, state)   -- 落盘
    online = false
    skynet.fork(function() skynet.sleep(0); skynet.exit() end)  -- 下一拍退出
end
```

实测 T3（断线前 hp=90，不重连）：

```
[PASS] T3.0   断线前状态 hp=90
[PASS] T3.1   超时后 agent 已 exit
[PASS] T3.2   超时后已存盘
[PASS] T3.3   存盘状态正确 hp=90
```

存盘内容（hp=90）与内存最后状态一致，证明退出前状态已正确落盘。

---

## 3. 热更新：把"会变的逻辑"拆出去

热更新的核心不是「怎么 reload」，而是**架构上把会变的逻辑和不会变的骨架分开**：

```
agent_reconnect.lua  (骨架：生命周期、fd、定时器、reload 接口)  —— 基本不动
        │ require
        ▼
shared/agent_logic.lua  (业务逻辑：state 结构、process 算法)    —— 经常变，热更对象
```

`agent_reconnect` 在 `spawn` 和 `reload` 时都走 `package.loaded[path]=nil; require(path)`：

```lua
local function load_logic()
    package.loaded[logic_mod] = nil
    logic = require(logic_mod)
end
```

热更流程（`hotfix_mgr` 统一编排）：

```lua
-- hotfix_mgr.deploy_v2：切版本 + 广播
function CMD.deploy_v2()
    current_path = "shared.agent_logic_v2"
    return CMD.broadcast()   -- 向所有注册 Agent 发 reload(current_path)
end

-- agent_reconnect.reload：就地重载
function CMD.reload(path)
    logic_mod = path or logic_mod
    load_logic()
    return true, logic.VERSION
end
```

实测 T4（运行中 Agent 在 v1 热更到 v2）：

```
[PASS] T4.0   初始逻辑版本 v1
[PASS] T4.1   热更后逻辑版本 v2 (原 v1)
[PASS] T4.2   热更后消息处理正常 hp=90
[PASS] T4.3   热更后 agent 仍存活（无崩溃）
```

Agent 在**不重启、不丢状态**的前提下切换了逻辑版本，且继续正常处理消息。

---

## 4. 向前兼容：热更添加新字段最易翻车的地方

热更最常见的需求是「给 state 加字段」（比如 v2 加 `mp` 魔法值）。但**旧 Agent 是在 v1 时期
创建的，它的 state 表里根本没有 `mp`**。如果 v2 的 `process` 假设 `state.mp` 一定存在，旧
Agent 热更后第一条消息就会 nil 崩。

正确做法：v2 在缺字段时**按默认值补齐**，而不是假设字段存在：

```lua
-- agent_logic_v2.lua
function M.process(state, msg)
    state.x = state.x + 1
    state.mp = state.mp or 100   -- 向前兼容：旧 agent 的 state 可能没有 mp
    if type(msg) == "table" and msg.dmg then state.hp = state.hp - msg.dmg end
    return state
end
```

实测 T5：

```
[PASS] T5.1   旧 agent 热更后新字段被默认补齐 mp=100  -- 旧 agent 兼容
[PASS] T5.2   新 agent 自带新字段 mp=100               -- 新 agent 正常
[PASS] T5.3   新 agent 处理正常 hp=90
```

旧 Agent（v1 创建、state 无 mp）热更到 v2 后，第一条消息触发 `state.mp = state.mp or 100`
补齐字段，继续正常工作；新 Agent（v2 环境下创建）天生带 `mp`。两者都正确——这就是热更添加
新字段必须做的**向前兼容迁移**。

---

## 5. 综合汇总（来自 make test 真实输出）

```
test_disconnect: 9 PASS, 0 FAIL
test_hotfix:     7 PASS, 0 FAIL
test_all:       16 PASS, 0 FAIL
=== TOTAL: 16 PASS, 0 FAIL ===
```

---

## 6. 仍未做的（演示边界）

- `db_stub` 是内存桩，进程重启即丢；生产替换为真实 MySQL/Redis（见 `ch7_db`）。
- 断线靠测试主动调 `gate.disconnect` 模拟；真实环境由 gateserver 检测 socket 关闭后发事件。
- 热更是「整模块替换」，非「函数级 patch」；无灰度/回滚，生产应加版本管理与 require 预检。
- 没有做热更失败回滚：新模块若 require 报错会保留旧 logic，应在 `hotfix_mgr` 侧先预检。
