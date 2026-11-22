# ch7_db 设计取舍与并发安全实测

> 依据：design.md Phase 4 —— 独立 DB 服务 + 连接池 + 存盘串行化

---

## 0. 一句话结论

**正确性不是免费的**：串行化让 20 次并发存盘的耗时从约 30 ms 涨到约 410 ms（**约 14 倍**），
但结果从"丢失 19 次更新"变成"完全正确"。

为了拿回这部分性能，做了**写合并**：100 次异步存盘合并成 **1 次**实际落盘。

---

## 1. 问题的本质：存盘是"读-改-写"，不是"写"

一次角色存盘通常长这样：

```
load(uid)  →  yield（网络往返）
  修改字段
save(uid)  →  yield（网络往返）
```

两个 yield 点之间，同一 uid 的另一个请求完全可以插进来：

```
A: load → hp=10
B: load → hp=10      ← 读到同样的旧值
A: save hp=11
B: save hp=11        ← A 的更新被覆盖
```

**两次 +1 只生效一次。** 这就是丢失更新（lost update）。

`skynet.queue` 按 uid 串行化可以根治：

```lua
local q = uid_queues[uid] or queue()
q(function()
    local conn = pool:acquire()
    local row  = conn:load_role(uid)      -- yield
    conn:save_role(uid, new_data)         -- yield
    pool:release(conn)
end)
```

> 关键认知：`q(f)` 会在**当前协程**执行 `f`。
> `f` 内部的 yield 只挂起当前协程，恢复后继续执行 ——
> 所以 `q(f)` 返回时 `f` 一定已完成，**天然具备"同步等待"语义**，
> 不需要额外的 done 标志或 skynet.wait。

---

## 2. 双向对照实验

同样的 20 次并发 `hp = hp + 1`：

| 配置 | 最终结果 | 耗时 | 结论 |
|---|---|---|---|
| 无 queue（`CH7_NO_QUEUE=1`） | hp = **1** | ~30 ms | 丢失 19 次更新，但很快 |
| 有 queue | hp = **20** | ~410 ms | 正确，慢约 14 倍 |

对照组（直接并发读写 driver，不经 db 服务）同样是 hp = 1。

**这个对照是双向的**：

- 有 queue → `C2.2 NO lost updates` 通过
- 关掉 queue（`make test-nq`）→ `C2.2` 失败（hp=1 expected=20）

只有两个方向都验证过，才能确认"是 queue 起的作用"，而不是别的因素。

> ⚠️ **对照组本身也必须是可信的**：
> `C1.2` 断言"对照组**必须**丢失更新"。
> 如果 mock 驱动没有注入 yield，读-改-写在单线程 Lua 里天然原子，
> 对照组会"通过"——那是**假绿**：什么都没验证。
> 所以 `shared/db_driver.lua` 用 `skynet.sleep(latency)` 模拟网络往返，
> 制造真实的交错窗口。**mock 不 yield，并发测试就是假的。**

---

## 3. 补偿优化：写合并（write coalescing）

串行化保证了正确性，代价是约 14 倍延迟。补偿手段是**少写几次**：

同一 uid 的**覆盖式**异步存盘，中间状态没有意义，只有最后一次重要。

```
100 次 save_async(hp=1..100)  →  实际只需 1 次落盘（hp=100）
```

实测：**100 次异步存盘 → 1 次实际写（合并 99 次）**。

### 安全性设计

合并不能破坏顺序保证，三条规则：

1. `save_sync` **接管 pending**：把未落盘的数据合并进来一起写，并清空 pending
2. flush 协程醒来发现 pending 为空则**跳过**，避免写回旧数据
3. flush 与 `save_sync` 走**同一条 `serial(uid)` 队列**，顺序仍然有保证

`C3` 专门验证：10 次 `save_async` + 1 次 `save_sync(hp=999)` → 最终 hp 必须是 999。

### 什么不能合并

**读-改-写不能合并**（`incr_hp`）。它的新值依赖旧值，跳过任何一次都会丢失更新。
合并只适用于"覆盖式写入"（直接赋值字段）。

---

## 4. 连接池

| 参数 | 默认 | 说明 |
|---|---|---|
| `min` | 1 | 最小保持数 |
| `max` | 8 | 常规上限 |
| `hard_max` | 32 | 扩容硬上限 |

- 无空闲连接时，先在 `hard_max` 内直接新建；真的到顶才用 `skynet.wait/wakeup` 挂起等待
- 等待用 `wait/wakeup`，**不用轮询**（轮询会引入 10ms 粒度延迟）
- 提供 `shrink()` 方法用于手动收缩（当前仓库未挂定时器，由调用方按需触发）

实测（C6）：并发 20 个慢操作时池 `total > min`（当次日志 `2 → 2`，2 为此前用例遗留），
结束后无等待者残留。（memory 驱动下连接是逻辑句柄，MySQL 模式下才会看到真实连接数增长。）

---

## 5. Agent 退出流程

`design.md` 关注的正是"防止一半 SQL 执行后 Agent 已退出"。顺序不能反：

```lua
function handlers.exit()
    while saving > 0 do skynet.sleep(1) end   -- 1. 等在途的异步存盘归零
    local ok = handlers.save_sync()           -- 2. 再补一次同步存盘
    -- 3. 之后才 skynet.exit()
    return ok
end
```

- 先 exit 再存盘 → 数据丢失
- 只等异步、不补同步 → 可能漏掉最后一次修改

`C4` 验证：Agent 发起异步存盘后立即退出，最终落盘数据完整（hp=75, gold=777）。

---

## 6. 隔离性

`C5`：一个 uid 执行 300ms 的慢操作时，另一个 uid 的 load 只用约 **8~11 ms**（当次实测 8.17~11.25ms）——
因为串行化是**按 uid** 的，不是全局的。这一点很关键：
全局串行化会让一个慢玩家拖垮整个服，按 uid 串行化只影响他自己。

---

## 7. 环境说明与双驱动实测

默认用 **memory 驱动**（注入 yield，可控），全部 37 用例无需数据库即可回归。

**已用真实 MySQL 8.4 完成双驱动对照**（`CH7_DB_DRIVER=mysql`，账号/建库见博客第 3.1 节）：

| 项目 | memory | 真实 MySQL 8.4 |
|---|---|---|
| 全量用例 | 37 PASS / 0 FAIL | 37 PASS / 0 FAIL |
| 反向对照（无 queue） | hp=1，13P1F | hp=1~2，13P1F |
| 有 queue（20 次 incr_hp） | ~30 ms | 396~473 ms（首次冷启动约 13 s，属异常值） |
| 慢 uid 隔离（C5） | 8.54 ms | 2.00~2.13 ms |

关键发现：真实驱动暴露了 memory 掩盖的 **D3.2 部分更新丢字段 bug**（mysql 原实现把未提供的 gold 抹成 0），已用 `COALESCE(新值, 旧列值)` 修复。skynet 的纯 Lua mysql 驱动不支持 `caching_sha2_password`，需专用账号 + `mysql_native_password`（MySQL 8.4 需在 mysqld.cnf 设 `mysql_native_password=ON`）。

---

## 8. 验证

```bash
# memory 驱动（默认）
wsl -d Ubuntu make -C ch7_db test              # 37 用例
wsl -d Ubuntu make -C ch7_db test-concurrency  # 只跑并发安全
wsl -d Ubuntu make -C ch7_db test-nq           # 反向对照（应当失败）

# 真实 MySQL 驱动
wsl -d Ubuntu env CH7_DB_DRIVER=mysql make -C ch7_db test      # 37 用例
wsl -d Ubuntu env CH7_DB_DRIVER=mysql make -C ch7_db test-nq   # 反向对照（应当失败）
```
