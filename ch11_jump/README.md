# ch11_jump — 分布式跳转（跨场景 / 跨节点平滑跳转）

基于 skynet cluster 的「玩家跨场景跳转」实现：一个 `node_a` 边缘节点（gate + scene_a）
承载在线玩家，另一个 `node_b` 场景节点（scene_b）作为跨节点跳转目标。演示如何把「跳转到
另一个进程里的场景」做成**状态不丢、消息不丢、失败可回滚**的平滑跳转。

> 完整设计目标见根目录 `design.md`（Phase 8）。本文档只描述本目录的实现与运行方式。

---

## 1. 架构

```
          ┌────────────────── node_a (127.0.0.1:2541) ──────────────────┐
 client ──▶│  gate_redirect (逻辑网关)                                  │
          │    · 维护 fd → {node, addr, window, buffer}                 │
          │    · 跳转窗口期缓存客户端消息，新 agent 就绪后重放           │
          │         │  begin_jump / rebind                              │
          │         ▼                                                    │
          │  agent_jumper(旧, scene_a) ─cluster.call─▶ scene_host(scene_b)│
          │    · 由旧 agent 发起跳转          · 创建新 agent 并返回地址   │
          └──────────────────────────────────┬──────────────────────────┘
                                              │ cluster.call("node_b","@scene_b","accept")
          ┌────────────────── node_b (127.0.0.1:2542) ──────────────────┐
          │  scene_host (scene_b) 创建新 agent_jumper，返回地址         │
          └─────────────────────────────────────────────────────────────┘
```

两个节点**共用同一份代码**（`main.lua` / `service/*.lua`），靠 skynet 启动时加载的 `.conf`
区分角色（`node_name`）。跳转的「重绑 fd」动作**必须在本节点（与 gate 同节点）用本地
`skynet.call` 完成**——跨节点用数字 handle 调 `cluster.call` 做重绑不可靠（见 `修复.md`）。

| 节点 | conf | node_name | cluster 端口 | 启动的服务 |
|------|------|-----------|--------------|-----------|
| node_a | `conf/node_a.conf` | `node_a` | 2541 | `gate_redirect` + `scene_host(scene_a)` + 测试 |
| node_b | `conf/node_b.conf` | `node_b` | 2542 | `scene_host(scene_b)`（常驻，被 Makefile kill） |

`scene_host` 在 cluster 命名空间注册 `@scene_a` / `@scene_b`，远端用
`cluster.call(target_node, "@scene_X", "accept", ...)` 寻址（**不要**用进程内的 service
handle 跨节点，那个 handle 在别的进程里毫无意义）。

---

## 2. 目录结构

```
ch11_jump/
├── conf/
│   ├── clustername.lua   # 节点地址表（node_a/node_b 的 ip:port），__nowaiting=true
│   ├── node_a.conf       # 边缘节点（gate + scene_a + 测试驱动）
│   └── node_b.conf       # 场景节点（scene_b）
├── service/
│   ├── gate_redirect.lua # 逻辑网关：fd→agent 映射 + 跳转窗口期消息缓存/重放
│   ├── scene_host.lua    # 场景服：accept 创建新 agent 并返回地址（不做跨节点重绑）
│   └── agent_jumper.lua  # 玩家 Agent（会跳转）：spawn / serialize / jump
├── test/
│   └── test_jump.lua     # 主测试（18 项，覆盖 T1–T4）
├── runtime.lua           # 配置加载（从 skynet.getenv 读 node_name / test_target）
├── main.lua              # 启动入口
└── Makefile
```

---

## 3. 运行

```bash
# 两节点跨进程跳转测试（node_b 后台常驻，node_a 前台跑测试 T1–T4）
make test

# 两节点常驻，手动调试（Ctrl-C 退出）
make run

# 清理日志
make clean
```

> 环境要求：WSL 下进入本目录再 make，例如 `wsl -d Ubuntu -- make -C <仓库根>/ch11_jump <target>`（`<仓库根>` 换成你自己的 clone 路径）。
> 注意 `MSYS_NO_PATHCONV=1`，否则 Windows 路径映射会出错。
>
> **不要在测试脚本里用 `pkill -f skynet`**——它的命令行里含 `skynet` 字样会误杀 WSL bash
> 自身（exit 9/126）。本 Makefile 改为后台启 node_b 并捕获其 PID，结束用 `kill $PID`。

### 可覆盖的环境变量（CH11_*，优先级高于 .conf）

| 变量 | 默认 | 说明 |
|------|------|------|
| `CH11_TEST_TARGET` | （取自 conf `test_target`） | 测试服务名；`test_jump` 跑跳转套件，`__none__` 表示常驻不跑测试（`make run` 用） |
| `CH11_NODE_NAME` | （取自 conf） | 覆盖节点名（单测用） |
| `CH11_CLUSTER_PORT` | （取自 conf） | 仅覆盖 `runtime.cluster_port` 字段；**实际监听端口由 `clustername.lua` 地址表决定**，`cluster.open` 只用节点名，改它不会改变监听端口 |

---

## 4. 跳转时序（核心）

以「node_a 上的玩家跳到 node_b/scene_b」为例：

```
Agent(旧, node_a)                Gate(node_a)                SceneHost(node_b)
      │ begin_jump(fd)                │ 打开窗口
      │──────────────────────────────▶│ window=true
      │                               │
      │ cluster.call("node_b",        │
      │   "@scene_b","accept",        │
      │   uid,fd,state,...)           │
      │ ──────────────────────────────────────────────────────▶│ newservice(agent)
      │                               │                         │ spawn(state)
      │                               │                         │ return true, new_addr
      │◀──────── return true,addr ────│◀────────────────────────│
      │                               │
      │ rebind(fd, "node_b", addr)    │ 重绑 fd→新 agent(node_b)
      │──────────────────────────────▶│ node=node_b, addr=addr
      │                               │ 关闭窗口 + 重放缓存消息
      │ (先 return，再 fork 退出)      │
      │ skynet.exit()                 │ 旧 agent 退出
```

关键约束：

1. **fd 重绑本节点做**：跳转方（旧 agent，与 gate 同节点）用本地 `skynet.call(gate,"rebind",...)`
   完成重绑；scene_host **只创建新 agent 并返回地址**，不做跨节点重绑。原因见 `修复.md` 坑 3。
2. **节点名不跨边界赌顺序**：`cluster.call` 同节点返回的多值顺序 / 数量可能与跨节点不一致，
   agent 不要依赖其多返回值的「目标节点名」，直接用自己已知的 `target_node`（见 `修复.md` 坑 4）。
3. **旧 agent 先回包再退出**：agent 在 `jump` 里先 `return`，再用
   `skynet.fork(function() skynet.sleep(0); skynet.exit() end)` 退出，否则调用方拿不到回包会
   报 `call failed`（见 `修复.md` 坑 2）。

---

## 5. 测试结果（来自 make test，18 PASS, 0 FAIL）

| 用例 | 验证点 | 结果 |
|------|--------|------|
| T1 同节点跳转 | fd 重绑成功，状态完整，旧 agent 退出 | PASS（T1.0–T1.4） |
| T2 跨节点跳转 | 目标场景服收到完整状态，fd 重绑到 node_b | PASS（T2.0–T2.4） |
| T3 窗口期缓存 | 跳转中客户端消息被 Gate 缓存后重放到新 agent | PASS（T3.1–T3.2） |
| T4 目标不可达 | 跳转失败，回滚到原场景，状态无丢失，agent 仍在线 | PASS（T4.0–T4.5） |

日志尾部 `cluster node [ghost] is absent.` 正是 T4 期望触发的回滚错误，已被 `pcall` 正确捕获。

---

## 6. 已知限制

- Gate 是「逻辑网关」简化版（不真开 socket 端口），只维护 `fd→agent` 路由表 + 窗口期缓存。
  生产里 Gate 是 `snax.gateserver` 管真实 socket，跳转窗口期的「客户端消息缓存」要挂在
  真实的 socket 缓冲 / agent 转发层上，思路一致但落地更复杂。
- 跳转是「停等式」：旧 agent 在 `jump` 内同步等 scene_host accept 完成才退出，期间该 fd 的
  新消息走 Gate 缓存。没有做「并行预拉取场景」之类的并发优化。
- 状态序列化是浅拷贝 table（`serialize` 返回字段副本），复杂引用（嵌套 table / 闭包）需要
  额外处理；生产应接 protobuf / 结构化存档。
