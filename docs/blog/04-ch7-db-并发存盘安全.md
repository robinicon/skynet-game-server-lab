---
title: [Skynet 手记] 20 次存盘丢了 19 次：一次并发存盘的真实对照实验
tags: [Skynet, Lua, 游戏服务器, 数据库, 并发安全, 连接池]
categories: 游戏服务器架构
abbrlink: ch7-db-concurrent-save
date: 2026-10-27
---

# [Skynet 手记] 20 次存盘丢了 19 次：一次并发存盘的真实对照实验

> **摘要**：同一份角色数据并发存 20 次，最终只生效了 1 次。本文用双向对照实验定位这个问题——不开串行化时结果错误但很快，开启后结果正确但慢一个数量级。为了拿回性能，实现了写合并：100 次异步存盘合并成 1 次落盘。文中还有一个容易被忽略的陷阱：**mock 数据库如果不 yield，你的并发测试是假绿的。** 早先版本的数字来自注入 yield 的 memory 驱动；本文已用真实 MySQL 8.4 重跑双驱动对照，补齐这条短板，并记录了真实驱动暴露、而 mock 掩盖的字段覆盖 bug。
>
> 系列文章：本系列基于《游戏服务器架构》第 4–12 章，用 cloudwu/skynet 逐章重新实现并优化。本文是第 7 章（MySQL 数据库），承接[第 6 章的双语言 ECS](./03-ch6-ecs-双语言ECS设计.md)。

---

## 一、开篇：问题的本质——存盘不是"写"，是"读-改-写"

一次角色存盘通常长这样：

```lua
local row  = db:load_role(uid)      -- yield（网络往返）
row.hp = row.hp + delta
db:save_role(uid, row)              -- yield（网络往返）
```

关键在两次 yield 之间。skynet 是事件驱动的，一个协程 yield 后，
同一服务的其他协程立刻可以运行。于是：

```
协程 A: load → hp=10
协程 B: load → hp=10      ← 读到完全相同的旧值
协程 A: save hp=11
协程 B: save hp=11        ← A 的更新被无声覆盖
```

**两次 +1，只生效了一次。** 这就是经典的丢失更新（lost update）。

`design.md` 给出的解法是：`用 skynet.queue 串行化同一 Agent 的存盘请求，
防止一半 SQL 执行后 Agent 已退出`。我把它实现并量化了代价。

---

## 二、实现：按 uid 串行化

```lua
local queue = require "skynet.queue"
local uid_queues = {}

local function get_q(uid)
    local q = uid_queues[uid]
    if not q then q = queue(); uid_queues[uid] = q end
    return q
end

local function serial(uid, f)
    return get_q(uid)(f)
end
```

> **一个容易误解的点**：`q(f)` 会在**当前协程**执行 `f`。
> `f` 内部的 yield 只挂起当前协程，恢复后继续执行 ——
> 所以 `q(f)` 返回时 `f` 一定已经完成，**天然具备"同步等待"语义**。
> 不需要额外的 done 标志，也不需要 `skynet.wait()`。
> 这一点从 `skynet.queue` 的源码看得很清楚：
> `xpcall_ret` 在 `f` 完成后才唤醒队列里的下一个。

---

## 三、双向对照实验

同样跑 20 次并发 `hp = hp + 1`。这里给出两套口径：**memory 驱动**（注入 yield，可控）与**真实 MySQL 8.4**（`CH7_DB_DRIVER=mysql`）。两套都做了双向对照。

| 驱动 | 配置 | 最终结果 | 耗时（稳态） | 结论 |
|---|---|---|---|---|
| memory | **无 queue**（`CH7_NO_QUEUE=1`） | hp = **1** | ~22 ms | 丢失 19 次更新，但很快 |
| memory | **有 queue** | hp = **20** | ~30 ms | 完全正确，慢约 14 倍 |
| **MySQL** | **无 queue**（`make test-nq`） | hp = **1~2** | ~346 ms | 真实网络往返下仍丢更新 |
| **MySQL** | **有 queue** | hp = **20** | ~400 ms | 完全正确 |

> 说明：C1 对照组（用于证明"mock 有效"）始终是注入 yield 的 memory 驱动——它需要**可控**的竞态窗口；真实 MySQL 的对照组是 `make test-nq`（关掉 db 服务的 queue）。两者角色不同，不能混为一谈。

```
# 实验组：真实 MySQL + queue（本轮实测）
=== C2: experiment group — 20 concurrent incr_hp WITH queue ===
  -- completed=20/20 in 403.2 ms, final hp=20 (expected 20)
  PASS  C2.2 NO lost updates with queue

# 反向对照：真实 MySQL，关掉 queue（make test-nq）
  -- completed=20/20 in 346.3 ms, final hp=1 (expected 20)
  FAIL  C2.2 NO lost updates with queue  hp=1 expected=20
```

注意一个反直觉的点：**真实 MySQL 下"无 queue"并不比"有 queue"快多少**（346 ms vs 400 ms）。因为 20 次真实网络往返本身占了绝大部分时间，串行化带来的额外等待被 I/O 掩盖了。这与 memory 模式"慢 14 倍"的观感完全不同——**性能代价的倍数，取决于你的 I/O 基线**。

**为什么要做双向对照？**

只做"有 queue 时正确"是不够的——可能你的测试数据本身就不会触发竞争。
必须验证"关掉 queue 就出错"，才能确认**是 queue 起的作用**。

我的做法是把两个方向都写成可执行的断言：
- 有 queue：`C2.2` 必须通过
- 关掉 queue（`make test-nq`）：`C2.2` 必须失败

### 3.1 用真实 MySQL 复测：补齐 memory-only 的短板

早先版本的全部数字都来自 memory 驱动——它注入 `skynet.sleep` 模拟 yield，能验证**调度语义**，但终究不是真实 I/O。MySQL 环境就绪后，我用 `CH7_DB_DRIVER=mysql` 把整套测试重跑了一遍，结果有三点值得记录。

**环境准备**（WSL Ubuntu / MySQL 8.4.13）：

```sql
CREATE DATABASE ch7_db DEFAULT CHARACTER SET utf8mb4;
USE ch7_db;
CREATE TABLE roles (
  uid INT PRIMARY KEY, hp INT NOT NULL DEFAULT 0,
  gold INT NOT NULL DEFAULT 0, version INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
```

踩了一个认证坑：skynet 的纯 Lua mysql 驱动（`lualib/skynet/db/mysql.lua`）走 sha1 握手，**不支持 MySQL 8 默认的 `caching_sha2_password`**，连上就报 `errno:1251 Client does not support authentication protocol`。解决办法是给驱动建专用账号并改用 `mysql_native_password`：

```sql
CREATE USER 'skynet'@'%' IDENTIFIED WITH mysql_native_password BY 'skynet123';
GRANT ALL PRIVILEGES ON ch7_db.* TO 'skynet'@'%';
```

MySQL 8.4 默认禁用该插件，需在 `mysqld.cnf` 加 `mysql_native_password=ON` 后重启。这是**驱动兼容性**问题，不是业务逻辑问题。

**真实驱动下的实测结果**（`ch7_db/log/mysql-verified/` 留有当次日志）：

| 项目 | memory 驱动 | 真实 MySQL 8.4 |
|---|---|---|
| 全量用例 | 37 PASS / 0 FAIL | 37 PASS / 0 FAIL |
| 反向对照（无 queue） | hp=1，13P1F | hp=1~2，13P1F |
| 有 queue（20 次 incr_hp） | ~30 ms | 396~473 ms（首次冷启动含建连握手，约 13 s，属异常值） |
| 慢 uid 隔离（C5） | 8.54 ms | 2.00~2.13 ms |
| 写合并（C7） | 100 → 1 落盘 | 100 → 1 落盘 |

**真实驱动暴露、而 mock 掩盖的 bug**：memory 驱动 `save_role` 是逐字段合并——只传 `hp` 时 `gold` 保留原值；而 mysql 驱动最初写成 `ON DUPLICATE KEY UPDATE hp=%d, gold=%d`，只传 `hp` 时会把 `gold` 抹成 0。`D3.2`（部分更新保留 gold）在 memory 下一直绿，切到 mysql 立刻红。修复方式是让 mysql 也遵循部分更新语义：

```sql
INSERT INTO roles (uid, hp, gold, version) VALUES (%d, %s, %s, 1)
ON DUPLICATE KEY UPDATE
  hp = COALESCE(%s, hp), gold = COALESCE(%s, gold), version = version + 1
```

新值为 `NULL` 时 `COALESCE` 取旧列值，等于不动这一列。修完后双驱动 37 用例全绿。这条恰好印证了本节的主题：**mock 只能验证逻辑，真实驱动才能验证 SQL 语义**。

---

## 四、最重要的陷阱：mock 不 yield，测试就是假绿的

写作这套测试时，最初并没有 MySQL 服务，于是先写了 memory 驱动。第一版是纯同步的：

```lua
function Memory:load_role(uid)
    return self.rows[uid]        -- 不 yield
end
```

结果：**并发测试全部通过，hp=20，一切正常。**

这是**假绿**。因为单线程 Lua 里，没有 yield 点的读-改-写天然是原子的——
协程 A 的 `load → 修改 → save` 根本不会被打断，竞争根本不会发生。

真实 MySQL 查询一定会 yield（网络往返），所以 mock 必须复现这个**调度语义**：

```lua
function Memory:_rtt(uid)
    if self.latency > 0 then
        skynet.sleep(self.latency)      -- 制造真实的 yield 点
    end
end

function Memory:load_role(uid)
    self:_rtt(uid)                       -- ← 关键
    return self.rows[uid]
end
```

改完之后，对照组立刻暴露出 19 次丢失更新。

**并且我把这一点固化成了断言**：

```lua
-- C1.2：对照组**必须**丢失更新，否则说明 mock 没 yield、测试无效
check("C1.2 control group LOSES updates (proves the test is meaningful)",
    hp_u < N, string.format("hp=%d N=%d", hp_u, N))
```

> **规则：异步系统的 mock 必须复现调度语义（yield 点），不只是复现返回值。**
> 否则你的并发测试只是在验证"单线程代码是顺序执行的"——一句废话。

---

## 五、补偿优化：写合并（write coalescing）

串行化带来明显延迟（memory 口径约 14 倍；真实 MySQL 下因网络往返占比高，倍数被压缩）。但仔细想想：**同一 uid 的多次覆盖式存盘，中间状态有意义吗？**

```
save_async(hp=1) → save_async(hp=2) → ... → save_async(hp=100)
```

中间 99 次写全是浪费，只有最后一次重要。

实现：把数据暂存在 `pending[uid]`，由 flush 协程延迟落盘：

```lua
function handlers.save_async(uid, data)
    local p = pending[uid]
    if p then
        for k, v in pairs(data) do p[k] = v end    -- 合并
        stat.merged = stat.merged + 1
    else
        pending[uid] = data
    end
    if flushing[uid] then return true end          -- 已有 flush 在途，它会带走最新数据

    flushing[uid] = true
    skynet.fork(function()
        skynet.sleep(FLUSH_DELAY)                  -- 合并窗口
        local d = pending[uid]
        pending[uid] = nil
        flushing[uid] = nil
        if d then do_write(uid, d) end             -- 仍走 serial(uid) 队列
    end)
    return true
end
```

实测：**100 次异步存盘 → 1 次实际落盘（合并 99 次）**。

### 三条安全规则

合并不能破坏顺序保证，否则会写回旧数据：

1. **`save_sync` 接管 pending**：把未落盘的数据合并进来一起写，并清空 pending
2. **flush 协程发现 pending 为空则跳过**，避免写回已被 sync 覆盖的旧值
3. **flush 与 `save_sync` 共用同一条 `serial(uid)` 队列**，顺序仍有保证

`C3` 验证：10 次 `save_async(hp=1..10)` + 1 次 `save_sync(hp=999)` → 最终必须是 **999**。

### 什么不能合并

**读-改-写不能合并。** `incr_hp` 的新值依赖旧值，跳过任何一次都会丢失更新。
合并只适用于"覆盖式写入"（直接赋值字段）。

---

## 六、按 uid 串行化，不是全局串行化

这一点很关键。如果串行化是全局的，一个执行慢查询的玩家会拖垮整个服。

`C5` 验证：某 uid 执行 300 ms 的慢操作时，另一个 uid 的 load：
- memory 驱动：**8.54 ms**；
- 真实 MySQL 驱动：**2.00~2.13 ms**（本轮实测，慢 uid 仍占 300 ms）。

两者都远小于 300 ms，说明不同玩家之间完全并行——串行化只发生在同一个 uid 内部。

---

## 七、Agent 退出的正确顺序

`design.md` 特别提到"防止一半 SQL 执行后 Agent 已退出"。顺序不能反：

```lua
function handlers.exit()
    while saving > 0 do skynet.sleep(1) end   -- 1. 等在途的异步存盘归零
    local ok = handlers.save_sync()           -- 2. 再补一次同步存盘
    -- 3. 之后才 skynet.exit()
    return ok
end
```

- **先 exit 再存盘** → 数据丢失
- **只等异步、不补同步** → 可能漏掉最后一次修改（修改发生在最后一个 async 发起之后）

`C4` 验证：Agent 发起异步存盘后立即退出，落盘数据完整（hp=75, gold=777）。

---

## 八、连接池的两个细节

**1. 等待不能用轮询**

```lua
-- ❌ 轮询会引入 10ms 粒度的固定延迟
while not conn do skynet.sleep(1) end

-- ✅ 用 wait/wakeup
local co = coroutine.running()
waiters[#waiters + 1] = co
skynet.wait(co)
return table.remove(self.free)     -- 被唤醒时 release 已放回连接
```

**2. 扩容要看等待队列**

无空闲连接时，如果有等待者说明负载高，允许在 `hard_max` 内新建；
否则只到 `max`。这样连接池能随负载自适应，而不是写死一个数字。

---

## 九、结论

**1. 串行化是正确的必要条件，但有延迟代价**
代价倍数取决于 I/O 基线：memory 口径约 14 倍，真实 MySQL 下被网络往返摊薄。不要指望"加了 queue 就完事"，要想办法减少写次数。

**2. 写合并是串行化的天然搭档**
覆盖式写入合并后，写次数降低 99%，把串行化的代价赚回来了。

**3. 验证并发安全必须做双向对照**
关掉保护后必须出错，否则你的测试没有验证任何东西。

**4. mock 必须 yield**
这是最容易踩的坑，而且踩了之后是"假绿"，比失败更危险。

---

## 十、复盘：五条可复用的经验

**1. 看到"并发写"，第一反应是找 yield 点**
丢失更新不发生在"写"这一刻，而发生在"读"和"写"之间的 yield 窗口。定位这类 bug，先在代码里标出所有 yield（`skynet.call`、`sleep`、网络 I/O），再看两个协程能否在窗口里交错。

**2. 保护机制要做双向对照，不能只测"开了就对"**
只验证"有 queue 时 hp=20"不够——可能你的数据根本不会触发竞争。必须同时验证"关掉 queue 就出错"（`make test-nq` 应 FAIL），才能证明是保护起了作用，而不是测试本身无效。

**3. mock 要复现调度语义，不只是返回值**
同步 mock 让读-改-写天然原子，并发测试全是假绿。给 mock 注入真实的 yield 点（`skynet.sleep(latency)`），才能暴露竞争。并把"对照组必须失败"写成断言，防止未来有人把 yield 去掉。

**4. 串行化是正确性底线，写合并是性能补救**
按 uid 串行化拉高延迟（倍数看 I/O 基线），但"覆盖式写入"的中间状态没有意义——合并后 100 次落盘变 1 次，把代价赚回来。注意读-改-写不能合并，merge 只适用于直接赋值。

**5. 串行化的粒度决定可用性**
按 uid 建队列而非全局锁：某玩家 300 ms 慢查询时，另一玩家 load 只花 8.54 ms（真实 MySQL 下 2.0~2.1 ms）。锁的粒度要落在"会互相竞争的数据"上，而不是"整个服务"。

---

## 十一、已知环境限制（重要）

- 本文耗时分两套口径：memory 驱动（28.5 ms / 408.7 ms / 约 14× / 8.54 ms，为写作时实测，复测约 22~30 ms / 400 ms）；真实 MySQL 8.4（有 queue 396~473 ms、无 queue 346 ms、隔离 2.0~2.1 ms，详见第 3.1 节）。均为实测记录，方法与断言可在仓库复现；毫秒数随 CPU / 网络 / 环境波动，结论（丢失更新、串行化正确性、写合并收益）不受影响，以 `ch7_db/log/` 下当次日志为准。
- 已用真实 MySQL 8.4 完成双驱动对照（全量 37 PASS / 反向对照 13P1F）。真实驱动下仍**未覆盖**网络断连、事务回滚、主从延迟等场景；测试账号用 `mysql_native_password` 仅为兼容 skynet 的纯 Lua 驱动，生产环境应改用支持 caching_sha2 的驱动或配置 TLS。
- 写合并的 `FLUSH_DELAY` 合并窗口意味着"异步存盘后立刻宕机"最多丢一个窗口内的更新——这是用一致性换性能的取舍，强一致场景请走 `save_sync`。

---

## 十二、代码与运行

```
ch7_db/
├── shared/db_driver.lua  # memory（注入 yield）/ mysql 双驱动
├── shared/connpool.lua   # wait/wakeup 等待 + 动态扩容
├── service/db.lua        # 按 uid 的 queue + 写合并
├── service/agent.lua     # 异步/同步存盘 + 退出落盘
└── test/                 # 37 用例
```

```bash
# 默认 memory 驱动
wsl -d Ubuntu make -C ch7_db test              # 37 用例
wsl -d Ubuntu make -C ch7_db test-concurrency  # 并发安全 + 对照
wsl -d Ubuntu make -C ch7_db test-nq           # 反向对照（应失败）

# 真实 MySQL 驱动（需先建 ch7_db 库与 roles 表，见 3.1 节）
wsl -d Ubuntu env CH7_DB_DRIVER=mysql make -C ch7_db test       # 37 用例
wsl -d Ubuntu env CH7_DB_DRIVER=mysql make -C ch7_db test-nq    # 反向对照（应失败）
```

---

> **数据说明**：本文耗时为 memory 与真实 MySQL 8.4 两套驱动下的实测记录（memory 约 22~30ms / 400ms / 8.54ms；MySQL 有 queue 396~473ms、无 queue 346ms、隔离 2.0~2.1ms），对照实验方法与断言均可在仓库中复现；毫秒数随环境波动，请以[仓库](https://github.com/robinicon/skynet-game-server-lab/tree/main/ch7_db) `ch7_db/log/` 下当次实测日志为准，结论（丢失更新、串行化正确性、写合并收益）不受影响。如果你的项目里有"存盘偶尔丢数据"的灵异现象，
> 大概率是本文第一节那个交错窗口——欢迎在评论区对一下症状。
