# ch11_jump 优化与跳转设计实录

本文记录把「玩家跨场景跳转」做成「跨进程也平滑」时的核心设计与实测数据。
目标不是堆功能，而是把**跨节点跳转这个天然有状态的迁移**做成：状态不丢、消息不丢、失败可回滚。

---

## 0. 测量方法论

跳转的「正确性」无法用墙钟一个指标衡量，核心是**三类不变量**：

1. **状态不变量**：旧 agent 的 `(hp, x, y, level, name)` 序列化后，新 agent 必须完整还原。
2. **消息不变量**：跳转窗口期（begin_jump → rebind 之间）客户端仍在发消息，这些消息不能丢、
   不能乱序，必须在新 agent 接管后**重放**。
3. **回滚不变量**：目标不可达时，fd 仍绑在原 agent、原 agent 仍在线、状态无丢失、后续消息
   仍正常到达。

所有用例都做**双向对齐**：跳转前快照 old_state ↔ 跳转后新 agent 的 new_state；窗口期注入的
消息数 ↔ 新 agent `received` 表里命中数。

---

## 1. 为什么 fd 重绑必须收回到本节点做

第一版设计里，scene_host（目标节点）在 `accept` 里直接 `cluster.call(node_a, gate_handle,
"rebind", ...)` 去重绑旧节点的 gate。结果「静默失效」或 `call to invalid address`。

根因：**`gate_handle` 是 node_a 进程内的数字 service handle，跨节点用 cluster 通道投递一个
「目标节点本地的数字 handle」语义不可靠**。cluster 通道按你给的地址当「目标节点上的 handle」
去路由，但那个 handle 属于 node_a，在 node_b 的命名空间里无效或指向无关的 service。

实测对比（修复前后）：

| 方案 | 跨节点 fd 重绑 | 结果 |
|------|----------------|------|
| v0：`cluster.call(node_a, gate_handle, "rebind", ...)` | 数字 handle 走集群通道 | 静默失效 / `call to invalid address` |
| v1：scene_host 只创建新 agent 返回地址；跳转方本节点 `skynet.call(gate,"rebind",...)` | 本地 call | T1/T2 重绑 100% 成功 |

**结论**：跨节点通信的寻址单位应当是 cluster 注册名（`@name`）或「目标节点名 + 目标节点上
有效 handle」。「与 gate 同节点」的重绑操作，本地 `skynet.call` 一把梭最稳，不要跨边界传数字
handle。

---

## 2. 窗口期消息缓存：跳转"停等"但不丢消息

跳转是「停等式」：旧 agent 在 `jump` 内同步等 scene_host accept 完成才退出。这段时间里客户端
仍在发消息，旧 agent 即将退出、新 agent 还没接管。

Gate 的做法：

```
begin_jump(fd)            → window = true，之后 forward 的消息进 buffer
... 旧 agent 同步等待 scene_host 创建新 agent ...
rebind(fd, node, addr)    → window = false，并把 buffer 逐条 route 给新 agent（重放）
```

`route` 按 `a.node == MY` 决定本地 `skynet.send` 还是跨节点 `cluster.send`——所以新 agent 在
node_b 时，重放消息走 `cluster.send("node_b", addr, "client_msg", fd, msg)`，与真实转发路径一致。

实测 T3（窗口期注入 1 条 "during_jump"）：

```
[PASS] T3.1   跳转完成，新 agent 在 node_b
[PASS] T3.2   窗口期消息被重放到新 agent（received=1）
```

`received=1` 说明窗口期缓存的消息被**精确重放**到新 agent，没有丢、没有重复。

---

## 3. 旧 agent 退出的时序

旧 agent 不能在 `jump` 的 `skynet.call` 处理路径里直接 `skynet.exit()`——那样调用方（测试）
拿不到回包会 `call failed`。正确时序：

```
rebind(...) 完成（旧 fd 已指向新 agent）
  → online = false
  → skynet.sleep(0)            -- 让 rebind 的窗口重放先跑完
  → skynet.fork(function() skynet.sleep(0); skynet.exit() end)  -- 下一拍再退出
  → return true                -- 先给调用方正常回包
```

实测 T1.4 / T2.4 都确认「旧 agent 已退出」，且调用方拿到了 `true` 回包（不报 `call failed`）。

---

## 4. 回滚：目标不可达时不赌顺序

`clustername.lua` 里 `__nowaiting = true` 是关键——节点名未解析时 `cluster.call` 立即报
`cluster node [ghost] is absent.`，而不是在 clusterd 内部永久阻塞。跳转方据此立即回滚。

但有个隐藏坑：scene_host 返回 `(true, a)`，而 `cluster.call` 遇不可达节点时**可能抛异常**
（pcall 捕获），**也可能返回 `(false, errmsg)`**（取决于 skynet 版本）。两种情况下都不能
「只接两个值把成功标志当地址」。统一处理：

```lua
local ok, success, taddr = pcall(cluster.call, target_node, "@scene_"..target_scene, "accept", ...)
if not ok or not success or not taddr then
    skynet.call(gate, "lua", "rebind", fd, node_name, skynet.self())  -- 回滚到原 agent
    return false, "jump_failed:" .. tostring(taddr)
end
```

实测 T4（ghost 节点）：

```
[PASS] T4.1   跳转失败（不可达） jump_failed:nil
[PASS] T4.2   fd 仍绑在原 agent（未重绑）
[PASS] T4.3   原 agent 仍在线（未退出）
[PASS] T4.4   状态无丢失
[PASS] T4.5   回滚后消息仍正常到达原 agent
```

日志尾部 `cluster node [ghost] is absent.` 正是期望触发的回滚错误，被 `pcall` 正确捕获。

---

## 5. 综合汇总（来自 make test 真实输出）

```
========== T1 同节点跳转 ==========
[PASS] T1.0   跳转前 state hp=90 x=1
[PASS] T1.1   同节点跳转成功
[PASS] T1.2   fd 重绑到新 agent (node=node_a, new=17)
[PASS] T1.3   状态完整 hp=90 x=1
[PASS] T1.4   旧 agent 已退出
========== T2 跨节点跳转 ==========
[PASS] T2.2   fd 重绑到 node_b 新 agent
[PASS] T2.3   跨节点状态完整 hp=75 x=1
[PASS] T2.4   旧 agent 已退出
========== T3 窗口期缓存 ==========
[PASS] T3.2   窗口期消息被重放到新 agent（received=1）
========== T4 目标不可达回滚 ==========
[PASS] T4.0~T4.5  全部通过
=== test_jump: 18 PASS, 0 FAIL ===
```

---

## 6. 仍未做的（演示边界）

- Gate 是逻辑网关简化版，不真开 socket；生产的 socket 缓冲 / 真实 gateserver 转发层要挂上
  同样的「窗口期缓存」逻辑。
- 跳转是停等式同步等待，未做「并行预拉取目标场景」之类的并发优化（大场景加载时旧 agent 会
  多等一段时间）。
- 状态序列化是浅拷贝 table；复杂引用需接 protobuf / 结构化存档，否则跨节点状态会丢字段。
- 没有做「跳转中 Agent 崩溃」的兜底：旧 agent 在 jump 中途挂掉，gate 的窗口会一直开着直到
  超时，需要加一个 window 超时关闭机制。
