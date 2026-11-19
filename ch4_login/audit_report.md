# ch4_login 架构审计报告（重构前·历史存档）

> 说明：本文是 **ch4 优化动手之前**的现状审计，文中 "目录尚未创建""center 用 uniqueservice" 等
> 均为当时的规划/设计意图。实现完成后，center 改用 `newservice` 单实例、工程已从零建成。
> 保留本文仅作"优化前 vs 优化后"的对照存档；当前状态请看同目录 `README.md` / `OPTIMIZATION.md`。

## 一、现有工程状态

`ch4_login/` 目录尚未创建，需从零实现。skynet 自带 `examples/login/` 可作为参考基础：

| skynet 内置 | 用途 |
|------------|------|
| `snax/loginserver.lua` | DH密钥交换 + HMAC挑战响应登录协议 |
| `snax/msgserver.lua` | Gate侧：用户在线表 + 握手认证 + 请求重发 |
| `examples/login/logind.lua` | 登录服务：auth_handler + login_handler |
| `examples/login/gated.lua` | Gate服务：loginserver 客户端代理 |
| `examples/login/msgagent.lua` | 玩家 Agent（含 client 协议注册） |
| `examples/login/client.lua` | 测试客户端（完整 DH+HMAC 握手） |

---

## 二、审计发现的问题

### 问题1：缺少 Token 机制（设计文档 §4）
- 现有 loginserver 用 DH 密钥交换验证身份，但没有独立的 "token" 概念
- 设计文档要求：登录后返回 uid + token，下次用 token 直接登录
- **需实现**：在 login_handler 之后签发 Lua token（uuid + HMAC签名），存入内存表，由 center 服务维护

### 问题2：缺少并发登录保护（设计文档 §4）
- `user_login[uid]` 在 loginserver.lua 中已存在，但只在 multilogin=false 时生效
- 设计文档要求：用 `skynet.queue` 串行化同一账号的登录请求，防止 top_account 竞争
- **需实现**：center 服务内部用 queue 保护，所有登录请求排队处理

### 问题3：缺少 Agent 生命周期管理
- skynet 示例的 msgagent 是 echo 服务，没有真正的玩家数据
- 设计文档要求：Agent 代表一个玩家，维护 uid、online 状态
- **需实现**：Agent 创建时向 center 注册，退出时注销

### 问题4：压力测试客户端需要完整握手
- `examples/login/client.lua` 实现了完整的 DH+HMAC 协议，但只测试 1 个客户端
- 1000 人压测需要批量启动能力，且不需要复杂的 sproto 业务层
- **需实现**：robot 服务模拟 N 个独立 TCP 连接，复用 loginserver 握手协议

### 问题5：无数据库依赖（环境限制）
- 当前 WSL 环境无 MySQL，skynet.db.mysql 不可用
- **方案**：使用内存表（Lua table）模拟，与 skynet 自带的 `simpledb.lua` 类似

### 问题6：maxclient 限制
- skynet gate 默认 `maxclient=1024`，1000 人压测会触及上限
- **需调整**：conf 中设置 `maxclient=2048` 或更高

---

## 三、优化方案

### 架构设计（3服务 + 1机器人）

```
login（loginserver lua服务，复用 snax.loginserver）
  │
  ├─ auth_handler   → 简单账号密码验证（内存字典）
  ├─ login_handler  → 签发token，注册到center
  │
center（uniqueservice，业务逻辑）
  │
  ├─ accounts[]     账号表（uid→{password, token}）
  ├─ online[]       在线状态（uid→{agent, token, server}）
  └─ login_queue    用skynet.queue串行化并发登录
  │
agent（每个玩家一个，由login_handler创建）
  │
  └─ uid, token, online标记
  │
robot（压测驱动）
  │
  └─ 批量发起连接，统计成功率/时延
```

### 优化点详细说明

#### 1. Token 设计
```lua
-- login_handler 返回 token
local token = generate_token(uid)  -- uuid_v4 + HMAC("secret", uid)
center[uid].token = token
return token  -- loginserver 通过 base64encode 返回给客户端
```

#### 2. 并发登录保护（核心优化）
```lua
-- center.lua 中用 skynet.queue 保护登录关键路径
local login_queue = skynet.queue(function(uid, password, ...)
    -- 串行执行：检查→签发token→创建agent
    -- 同账号并发请求不会race
end)
skynet.call(login_queue, "lua", "push", uid, password)
```

#### 3. Robot 服务设计
- 使用 skynet 内置的 `socket.connect` 发起 TCP 连接
- 复用 loginserver 的 DH+HMAC 握手协议（无需重写协议）
- 批量启动 N 个 fork 协程，每个独立连接
- 记录：总时间、成功数、失败数、平均时延

#### 4. 配置优化
- `maxclient = 2048`（支持 1000 压测）
- `thread = 16`（增加并发处理能力）
- `logger = nil`（压测时减少日志 IO 开销）

---

## 四、1000人登录测试用例设计

### 测试场景

| 编号 | 用例名 | 预期结果 | 验证方式 |
|------|--------|---------|---------|
| T1 | 单账号合法登录 | uid + token 返回，center.online 记录存在 | test_login.lua |
| T2 | 未知账号登录 | 返回错误码，center 无记录 | test_login.lua |
| T3 | 同账号并发登录 | 第二次登录被拒绝（login_queue 串行保护） | test_center.lua |
| T4 | Token 验证 | 有效 token 返回 uid，无效 token 返回 nil | test_center.lua |
| T5 | 1000人并发登录 | 全部成功（100%成功率），无崩溃 | stress_1000.lua |
| T6 | 登录后断线重连 | 用同一 token 重连，获取原 uid | stress_1000.lua |

### T5 压测指标

- **成功率**：1000/1000
- **平均登录时延**：< 50ms/次
- **P99 时延**：< 200ms
- **内存增长**：压测后 center 进程 RSS < 50MB
- **无数据竞争**：无任何 nil/异常 error 日志

### 测试执行流程

```bash
# 1. 启动服务器（单节点）
wsl -d Ubuntu make -C ch4_login run

# 2. 运行单元测试
wsl -d Ubuntu make -C ch4_login test

# 3. 运行1000人压测（后台启动服务器，前台跑测试）
wsl -d Ubuntu make -C ch4_login stress
```

---

## 五、文件清单

```
ch4_login/
├── Makefile              # 构建+测试目标
├── config                # skynet 配置文件
├── scripts/
│   ├── main.lua          # 启动入口：login + center + agent
│   ├── login.lua         # 登录服务（wrap snax.loginserver）
│   ├── center.lua        # 账号/Token管理（uniqueservice）
│   ├── agent.lua         # 玩家Agent（内存状态）
│   └── robot.lua         # 压测机器人（TCP + DH握手）
└── test/
    ├── test_login.lua    # T1-T2：单账号登录
    ├── test_center.lua   # T3-T4：并发保护 + Token验证
    └── stress_1000.lua   # T5-T6：1000人压测
```
