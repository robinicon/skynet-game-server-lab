# ch4_login 工业级分层架构设计

> 更新：2026-10-26（P0–P3 优化实施后同步）

## 分层原则

```
conf/          ← 配置层（不依赖任何层）
shared/        ← 公共工具（仅依赖 Lua stdlib / skynet）
proto/         ← 协议定义（仅依赖 shared/）
service/       ← 业务逻辑（依赖 proto/ + shared/）
gateway/       ← 网关入口（依赖 service/ + proto/ + shared/）
test/          ← 测试（依赖所有层）
```

**依赖方向严格向下，禁止反向依赖。**

---

## 各层职责

### conf/ — 配置层
- `skynet.conf`：Skynet 核心参数（端口、线程数、maxclient）+ 业务参数（gate_port / backlog / agent_prewarm）
- 不包含任何业务逻辑

### shared/ — 公共工具层
- `error_code.lua`：统一错误码枚举
- `token.lua`：Token 生成（128bit 随机串，不做哈希）
- `utils.lua`：通用工具（safe_call、us_between、percentile、average_us）
- `service.lua`：**统一服务骨架**（命令表 dispatch + pcall 兜底 + send/call 区分 + 自动回包）

### proto/ — 协议层
- `game.proto`：sproto 定义（login_req / login_resp / Ping / Pong / echo）
- `proto.lua`：sproto 编译加载器（compile + cache）

### service/ — 业务服务层
- `center.lua`：账号管理 + Token 索引 + 在线状态 + 分桶过期清理 + 指标统计
- `agent.lua`：玩家 Agent（**独立 snlua 服务**，池化复用）

### gateway/ — 网关入口层
- `gated.lua`：Gate 服务（wrap `snax.gateserver`，fd↔uid↔agent，登录握手 + 业务转发）
- `login.lua`：登录服务（认证委托 center；Agent 对象池管理者）
- `main.lua`：启动入口（初始化所有服务、预热 agent 池、汇总测试结果）

### test/ — 测试层
- `test_login.lua`：T1/T2 单账号登录
- `test_center.lua`：T3/T4/T7 并发保护 + Token 验证 + 指标
- `stress_center.lua`：T5/T6 center 单点吞吐压测（不走网络）
- `stress_e2e.lua`：T8 端到端压测（TCP + sproto + agent）——**性能数字以此为准**
- `robot.lua`：TCP 机器人客户端（gate 包格式封装）

---

## 关键设计决策

### 1. Token 机制
- 登录成功后 center 生成 `base64(randomkey() × 2)`（128bit 随机串），**不做哈希、不内嵌 uid/时间戳**
- center 维护 `token_index[token] = {uid, expire_at}` 反查归属与有效期
- 校验退化为一次 hash 查找 + 过期判断，零哈希开销
- 登出只清 `online`，token 保留至过期，支持 `login_by_token` 免密重连

### 2. 并发登录保护
- center 是单服务，lua 消息天然串行调度，**不需要额外 `skynet.queue`**
- top_account 场景通过 `online[uid]` 存在性判断拒绝重复登录
- 若未来按 uid 分片，串行性由分片内保证

### 3. Agent 生命周期与对象池
```
login_handler 从池取 agent → agent.start() 向 center 注册 → center.online[uid].agent = addr
客户端断开 → gate 通知 agent afk → center 注销 → agent 归还池（不退出，等待复用）
```
- 池化原因：实测 `newservice("agent")` 在登录关键路径上占 25~29ms（auth 仅 0.5~1ms）
- 预热 128 个并对每个调一次 `warmup()`，消除 ~28ms 的服务冷唤醒成本

### 4. 过期清理
- 300s 分桶：token 按 `expire_at / 300` 入桶，到期整桶回收，避免全表 `pairs`
- 仍在线且已绑定 agent 的 token 自动续期
- 定时器 `skynet.sleep(6000)`（单位 1/100 秒 = 60 秒）

### 5. 错误处理
- 所有服务用 `shared/service.lua` 骨架：handler 抛异常 → 返回 `ERR_INTERNAL`，调用方不会挂死
- gateway 层只处理网络 I/O 异常，业务错误由 service 层返回码表达

### 6. 服务命名
- 网关服务名必须是 `gated`，不能用 `gate`：`../skynet/service/?.lua` 下存在同名内置服务
- `luaservice` 中本地路径排在 `../skynet/service/?.lua` 之前，进一步避免撞名

---

## 线上协议（Gate 之上）

```
上行：2 字节长度(不含自身) + payload + 4 字节 session
下行：2 字节长度(不含自身) + content + 1 字节 ok + 4 字节 session

第一包 payload = sproto(login_req)         → 登录握手
后续包 payload = 1 字节 cmd + sproto body  → 业务消息（1=ping, 2=echo）
```
