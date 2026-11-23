# ch10_distributed — 分布式登录与跨节点容错

基于 skynet cluster 的三节点登录系统：一个 `auth` 接入节点 + 两个 `center` 中心节点。
演示如何在「跨进程调用」这个天然不可靠的链路上做**超时保护、熔断、本地缓存、一致性哈希**，
把裸 `cluster.call` 的「会永久挂死」变成「可控地失败」。

> 完整设计目标见根目录 `design.md`（Phase 7）。本文档只描述本目录的实现与运行方式。

---

## 1. 架构

```
                ┌──────────────────────────────────────────────┐
   client ──────▶│  auth 节点 (login_gateway)   cluster :2531   │
                │   · 一致性哈希选 center                        │
                │   · 本地 token 缓存 (TTL)                     │
                │   · 登录校验走跨节点 cluster.call              │
                └───────┬──────────────────┬───────────────────┘
                        │ cluster.call      │ cluster.call
                        ▼                   ▼
            ┌────────────────────┐  ┌────────────────────┐
            │ center1  :2532     │  │ center2  :2533     │
            │  center_dist       │  │  center_dist       │
            │   └ redis_auth     │  │   └ redis_auth     │
            │     (token 存储)   │  │     (token 存储)   │
            └────────────────────┘  └────────────────────┘
```

三个节点**共用同一份代码**（`main.lua` / `runtime.lua`），靠 skynet 启动时加载的那份
`.conf` 区分角色：

| 节点 | conf | node_name | cluster 端口 | 启动的服务 |
|------|------|-----------|--------------|-----------|
| auth | `conf/node_a.conf` | `auth` | 2531 | `login_gateway` |
| center1 | `conf/node_b.conf` | `center1` | 2532 | `center_dist` + `redis_auth` |
| center2 | `conf/node_c.conf` | `center2` | 2533 | `center_dist` + `redis_auth` |

`center_dist` 在 cluster 命名空间里注册名字 `@center`，远端用
`cluster.call(node, "@center", cmd, ...)` 寻址（**不要**用进程内的 service handle 跨节点，
那个 handle 在别的进程里毫无意义）。

---

## 2. 目录结构

```
ch10_distributed/
├── conf/
│   ├── clustername.lua   # 节点地址表（auth/center1/center2 的 ip:port）
│   ├── node_a.conf       # auth 接入节点
│   ├── node_b.conf       # center1
│   └── node_c.conf       # center2
├── shared/
│   ├── dist_call.lua     # 跨节点调用封装：超时 + 熔断 + 计数
│   └── balance.lua       # 一致性哈希选节点（FNV-1a）
├── service/
│   ├── login_gateway.lua # 登录接入（auth 节点）
│   ├── center_dist.lua   # 分布式中心服（center 节点）
│   └── redis_auth.lua    # token 存储/校验（memory / redis 双后端）
├── test/
│   ├── test_cluster.lua  # 主测试（36 项）
│   └── test_hang.lua     # 对照组：裸 cluster.call 会挂死
├── runtime.lua           # 配置加载（从 skynet.getenv 读业务配置）
├── main.lua              # 启动入口
└── Makefile
```

---

## 3. 运行

```bash
# 三节点跨进程测试（auth + center1 + center2）
make test

# 对照组：证明裸 cluster.call 在目标假死时会挂死（被 timeout 强杀 rc=124）
make test-hang

# 三个节点常驻，手动调试
make run

# 清理日志
make clean
```

> 环境要求：WSL 下进入本目录再 make，例如 `wsl -d Ubuntu -- make -C <仓库根>/ch10_distributed <target>`（`<仓库根>` 换成你自己的 clone 路径）。
> 注意 `MSYS_NO_PATHCONV=1`，否则 Windows 路径映射会出错。

### 可覆盖的环境变量（CH10_*，优先级高于 .conf）

| 变量 | 默认 | 说明 |
|------|------|------|
| `CH10_CALL_TIMEOUT` | 100 | 单次跨节点调用超时（cs，1cs=10ms） |
| `CH10_CB_THRESHOLD` | 3 | 连续失败几次后熔断 |
| `CH10_CB_COOLDOWN` | 300 | 熔断冷却时长（cs） |
| `CH10_CACHE_TTL` | 3000 | gateway 本地 token 缓存时长（cs = 30s） |
| `CH10_VNODES` | 128 | 一致性哈希虚拟节点数 |
| `CH10_REDIS_BACKEND` | memory | `memory` / `redis`（默认 memory，环境无 redis） |
| `CH10_REDIS_HOST/PORT/DB` | 127.0.0.1:6379/0 | redis 后端连接参数 |

---

## 4. 核心设计取舍

1. **为什么要包一层 `dist_call`**：裸 `cluster.call` 在「目标假死」或「节点名未解析且
   `__nowaiting=false`」时会**永久阻塞**，调用方既拿不到超时也拿不到错误。封装后加超时
   （放弃等待）+ 熔断（连续失败 fail-fast）+ 计数（可观测）。见 `shared/dist_call.lua`。

2. **返回值约定**：所有跨节点接口**至少返回 2 个值，第一个是业务 ok**。这样
   `pack.n == 1 and pack[1] == false` 唯一地表示「网络/框架层失败」，与「业务返回
   `false` + 具体原因（2 个值）」区分开。否则单值 `false` 时无法判断是网络失败还是
   业务失败且没给原因，重试/熔断策略就会做错。

3. **本地缓存 vs 一致性**：gateway 缓存 token（uid 维度 TTL），把重连/频繁登录的
   `O(N)` 次 RPC 压成 `O(1)` 次；代价是 token 被吊销后最长有 TTL 窗口期仍有效——对
   「踢下线」这类强一致需求必须走 center 的删除 + 广播失效（本章未实现 `del`，生产需补），
   不能只靠 TTL。

4. **一致性哈希选节点**：同一 uid 恒定命中同一 center，center 侧才能做本地缓存收敛和
   在线状态收敛；节点变化时只迁移 `1/N` 的 key。哈希用 FNV-1a，避免 djb2 对短数字串
   分布退化的坑（详见 `修复.md`）。

5. **`send` 高频路径**：上报在线用 `cluster.send`（不等回包），把同步阻塞的登录链路里
   的高频旁路异步掉。实测 500 次 send 0.28ms vs 500 次 call 94ms。

---

## 5. 测试结果（摘）

全部来自 `make test`（36 PASS, 0 FAIL）：

- 负载分布：1000 次登录 → center1=485 / center2=515（偏差 6%）
- 单次跨节点登录均值 **0.234 ms**
- `send` 500 次 **0.28 ms** vs `call` 500 次 **94.28 ms**
- 128KB 大包往返 **3.22 ms**
- 故障注入：目标假死 → 超时 993.9ms（设 1000ms）；节点名未解析 → 超时 496.9ms（设 500ms）
- 熔断：连续 3 次超时 → open；熔断期内 fail-fast **26μs**（对照真实调用 300+μs）

完整用例与数据见 `test/test_cluster.lua` 输出及 `OPTIMIZATION.md`。

---

## 6. 已知限制

- 默认 `memory` 后端：token 存在 center 进程内存，进程重启即丢。生产用
  `CH10_REDIS_BACKEND=redis` 且真的有 Redis 时切换到共享存储。
- `dist_call` 的超时只是「放弃等待」，既不能取消已发出的请求，也不能回收被阻塞的协程
  （被放弃的会计入 `leaked`）。生产必须配合节点健康探测 + 熔断，必要时靠 watchdog 重启。
- center 是无状态的（token 在 redis_auth），本实现未做 center 自身的多副本选主/故障转移，
  属于演示范围。
