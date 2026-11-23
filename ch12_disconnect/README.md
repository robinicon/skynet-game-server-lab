# ch12_disconnect — 断线重连 + 热更新

基于 skynet 的「断线延迟销毁」与「运行中热更新」实现：玩家掉线不立即销毁 Agent，留一个
重连窗口；窗口内重连则原地复活，超时则存盘退出。同时支持**不重启进程**地把玩家业务逻辑
模块热替换成新版本，且旧 Agent 的状态向前兼容新字段。

> 完整设计目标见根目录 `design.md`（Phase 9）。本文档只描述本目录的实现与运行方式。

---

## 1. 架构（单节点）

```
                 ┌────────────────── node_a (单进程) ──────────────────┐
                 │                                                      │
   client ──────▶│  gate_reconnect（逻辑网关）                          │
                 │    · fd → agent 映射                                 │
                 │    · disconnect / reconnect 事件                     │
                 │         │ bind / on_disconnect / on_reconnect        │
                 │         ▼                                            │
                 │  agent_reconnect（玩家 Agent）                       │
                 │    · offline 定时器（超时存盘+退出）                  │
                 │    · reload(path) 热更新逻辑                         │
                 │         │ require("shared.agent_logic[_v2]")         │
                 │         ▼                                            │
                 │  hotfix_mgr（热更广播，uniqueservice）               │
                 │    · 维护 current_path + 注册 Agent 列表             │
                 │    · deploy_v2() 切版本 + 广播 reload                 │
                 │         │ save / get                                  │
                 │         ▼                                            │
                 │  db_stub（内存存盘桩，uniqueservice）               │
                 └──────────────────────────────────────────────────────┘
```

本议题**不需要 cluster**（断线/热更都在单节点内），因此一次进程跑完所有用例，没有
ch11 那种 WSL 多进程复杂度。

---

## 2. 目录结构

```
ch12_disconnect/
├── conf/
│   └── node.conf         # 单节点配置（bootstrap = snlua bootstrap）
├── shared/
│   ├── agent_logic.lua   # 玩家业务逻辑 v1（可热更模块）
│   └── agent_logic_v2.lua# 玩家业务逻辑 v2（新增 mp 字段，模拟"线上新版本"）
├── service/
│   ├── gate_reconnect.lua # 逻辑网关：fd→agent 映射 + 断线/重连事件
│   ├── agent_reconnect.lua# 玩家 Agent：offline 定时器 + 重连 + 热更 reload
│   ├── hotfix_mgr.lua    # 热更新广播管理器（uniqueservice 单例）
│   └── db_stub.lua       # 内存存盘桩（uniqueservice 单例，演示落盘链路）
├── test/
│   ├── test_disconnect.lua# T1/T2/T3
│   ├── test_hotfix.lua   # T4/T5
│   └── test_all.lua      # 综合入口，依次跑上面两个
├── runtime.lua           # 配置加载（skynet.getenv 读 node_name / test_target）
├── main.lua              # 启动入口
└── Makefile
```

---

## 3. 运行

```bash
# 单进程跑全部用例（T1–T5，断线重连 + 热更新）
make test

# 常驻，手动调试
make run

# 清理日志
make clean
```

> 环境要求：WSL 下进入本目录再 make，例如 `wsl -d Ubuntu -- make -C <仓库根>/ch12_disconnect`（`<仓库根>` 换成你自己的 clone 路径）。
> 注意 `MSYS_NO_PATHCONV=1`。本议题单进程，无后台进程、无 `pkill` 陷阱。

### 可覆盖的环境变量（CH12_*，优先级高于 .conf）

| 变量 | 默认 | 说明 |
|------|------|------|
| `CH12_TEST_TARGET` | （取自 conf `test_target`=`test_all`） | 测试服务名 |
| `CH12_NODE_NAME` | （取自 conf） | 覆盖节点名 |
| `CH12_OFFLINE_TIMEOUT` | 100 | 断线后等待重连的超时（cs，1cs=10ms） |

---

## 4. 核心设计取舍

1. **断线延迟销毁**：`on_disconnect` 只标记 `offline` 并启动一个超时定时器，**不立即 exit**。
   这样重连窗口内的玩家不会被销毁（测试用例 T2 中重连均成功）。超时仍未重连才 `save_and_exit`
   （存盘 + 退出），避免无限占用资源。

2. **重连是"换 fd 不换 Agent"**：重连时新 fd 绑定回**原来的 Agent**，取消定时器、恢复
   `online`。玩家状态始终在原来的 Agent 里，重连零状态迁移、零加载。

3. **热更新 = "拆出会变的逻辑"**：把真正算数的业务逻辑放在 `shared/agent_logic.lua`，
   Agent 骨架（`agent_reconnect`）只负责生命周期。热更只需 `package.loaded[name]=nil`
   + 重新 `require`，切换 `current_path` 并广播，运行中 Agent 就地重载，**无崩溃、无状态丢失**。

4. **向前兼容迁移**：v2 新增 `mp` 字段时，旧 Agent（v1 时期创建，state 无 `mp`）在热更后
   处理消息时**按默认值补齐**字段，而不是假设字段一定存在（否则 nil 崩）。这是热更添加
   新字段时必须做的兼容处理。

5. **uniqueservice 做单例**：`hotfix_mgr` / `db_stub` 用 `skynet.uniqueservice` 保证全节点
   单例，Agent 内部按名字就能取到同一实例，不用层层传递 handle。

---

## 5. 测试结果（来自 make test，16 PASS, 0 FAIL）

| 用例 | 验证点 | 结果 |
|------|--------|------|
| T1 断线 | Agent 进入 offline（未 exit） | PASS（T1.1–T1.2） |
| T2 重连 | fd 重绑到新 fd，恢复 online | PASS（T2.1–T2.3） |
| T3 超时 | 未重连 → Agent exit + 存盘，状态正确 | PASS（T3.0–T3.3） |
| T4 热更 | 运行中 Agent 重载到 v2，无崩溃，处理正常 | PASS（T4.0–T4.3） |
| T5 新字段 | 旧 Agent 兼容（mp 补齐）、新 Agent 正常 | PASS（T5.1–T5.3） |

> 日志尾部有一行 `skynet.lua:375` 的 assert traceback——那是进程 `os.exit` 拆卸时、某个
> 已退出服务队列里残留的异步消息被投递导致的 skynet 已知拆卸副作用，不涉及任何业务逻辑，
> 测试计数与退出码均正常（详见 `修复.md` 坑 3）。

---

## 6. 已知限制

- `db_stub` 是内存桩，进程重启即丢；生产替换为真实 MySQL/Redis（见 `ch7_db`）。
- 断线判定靠测试主动调 `gate.disconnect` 模拟；真实环境应是 gateserver 检测到 socket 关闭
  后发 `disconnect` 事件。
- 热更是「整模块替换」，不是「函数级 patch」；需要保留旧逻辑的灰度/回滚要另做版本管理。
- 没有做「热更失败回滚」：若新模块 require 报错，Agent 会保留旧 logic（reload 包在 Agent
  内部未强保护），生产应加 try/catch + 版本回退。
