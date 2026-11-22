# ch7_db — MySQL 数据库服务

> 《游戏服务器架构》第 7 章的 Skynet 实现。
> 独立 DB 服务 + 连接池 + 存盘串行化 + 写合并。

---

## 快速开始

```bash
# 全部测试（37 用例）
wsl -d Ubuntu make -C ch7_db test

# 只跑 CRUD 与连接池
wsl -d Ubuntu make -C ch7_db test-db

# 只跑并发存盘安全（含对照实验）
wsl -d Ubuntu make -C ch7_db test-concurrency

# 反向对照：关闭 skynet.queue（应当观测到丢失更新，C2.2 会失败）
wsl -d Ubuntu make -C ch7_db test-nq

# 切换到真实 MySQL（需先建 ch7_db 库与 roles 表，见博客第 3.1 节）
CH7_DB_DRIVER=mysql wsl -d Ubuntu make -C ch7_db test
CH7_DB_DRIVER=mysql wsl -d Ubuntu make -C ch7_db test-nq   # 反向对照（应失败）
```

默认用 **memory 驱动**（注入 yield），全部用例无依赖即可回归。
**已用真实 MySQL 8.4 完成双驱动对照**：两者全量均 37 PASS / 0 FAIL，反向对照均 13P1F（观测到丢失更新）；耗时与差异见 `OPTIMIZATION.md` 第 7 节。真实驱动还暴露了 memory 掩盖的部分更新 bug（D3.2），已修复。

---

## 目录

| 路径 | 说明 |
|---|---|
| `shared/db_driver.lua` | 驱动抽象：memory（默认，**注入 yield**）/ mysql |
| `shared/connpool.lua` | 连接池：`wait/wakeup` 等待，动态扩容 |
| `service/db.lua` | DB 服务：按 uid 的 `skynet.queue` + 写合并 |
| `service/agent.lua` | 模拟 Agent：异步/同步存盘 + 退出落盘 |
| `test/test_db.lua` | CRUD 与连接池（23 断言） |
| `test/test_concurrency.lua` | 并发安全 + 对照实验（14 断言） |

---

## 核心数据

| 场景 | 结果 | memory 耗时 | 真实 MySQL 耗时 |
|---|---|---|---|
| 20 次并发 `hp+1`，**无 queue**（经 db 服务，`make test-nq`） | hp = **1~2**（丢失 18~19 次） | ~22 ms | ~346 ms |
| 20 次并发 `hp+1`，**有 queue** | hp = **20**（正确） | ~30 ms | 396~473 ms |
| 20 次并发直连 driver（C1，无 queue） | hp = **1**（丢失 19 次） | ~22 ms | 对照组仍是 memory（需可控竞态） |
| 100 次异步存盘（写合并） | **1 次**实际落盘（合并 99） | — | — |
| 慢 uid 阻塞时其他 uid 的 load | 未阻塞 | 8.54 ms | 2.00~2.13 ms |

**正确性换来延迟（memory 口径约 13~14 倍；真实 MySQL 下被网络往返摊薄），再用写合并把写次数降低 99%。**
（以上为当次实测值，毫秒数随机器/调度波动；结论"丢失更新、串行化正确性、写合并收益"稳定。两套驱动均已跑通，详见 `OPTIMIZATION.md` 第 7 节。）

---

## 三条关键设计

**1. 按 uid 串行化，不是全局串行化**
全局串行化会让一个慢玩家拖垮整个服。`C5` 验证：某 uid 执行 300ms 慢操作时，
其他 uid 的 load 只用约 8~11 ms（当次实测 8.17~11.25ms，未阻塞）。

**2. 写合并只适用于覆盖式写入**
```
100 次 save_async(hp=1..100) → 1 次落盘（hp=100）
```
读-改-写（`incr_hp`）**不能合并**，它的新值依赖旧值。

**3. Agent 退出流程的顺序不能反**
```lua
-- 1. 等在途异步归零（必须带超时上限，防止存盘服务假死时永久卡住）
local waited = 0
while saving > 0 and waited < 500 do skynet.sleep(1); waited = waited + 1 end
local ok = save_sync()                    -- 2. 补一次同步存盘
-- 3. 由退出方（main）在 exit 返回后再 skynet.exit()，避免 call 未回包
```

---

## API

```lua
-- 异步（常规路径，会被合并）
skynet.send(db, "lua", "save_async", uid, { hp = 100, gold = 50 })
-- 同步（退出/关键节点，阻塞到落盘，会接管未落盘的 pending）
skynet.call(db, "lua", "save_sync", uid, { hp = 100 })
-- 读
local row = skynet.call(db, "lua", "load", uid)      -- 不存在返回 nil，不报错
-- 读-改-写（并发安全）
local hp = skynet.call(db, "lua", "incr_hp", uid)
-- 运维
skynet.call(db, "lua", "stats")     -- driver / pool / io(merged,writes) / queues
skynet.call(db, "lua", "reset")     -- 清库（测试用）
```

`skynet.queue` 的 `q(f)` 在当前协程执行 `f`，
`f` 内 yield 只挂起当前协程，恢复后继续 —— **返回时 f 一定已完成**，
天然具备同步等待语义，不需要额外的 done 标志。

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `CH7_TEST_TARGET` | — | `test_db,test_concurrency` |
| `CH7_DB_DRIVER` | memory | `memory` / `mysql` |
| `CH7_NO_QUEUE` | 0 | `1` = 关闭串行化（**对照实验**，会丢失更新） |
| `CH7_NO_COALESCE` | 0 | `1` = 关闭写合并 |
| `CH7_FLUSH_DELAY` | 1 | 合并窗口（tick，1 tick = 10ms） |
| `CH7_CONCURRENCY_N` | 20 | 并发数 |

---

## 相关文档

- [`OPTIMIZATION.md`](OPTIMIZATION.md) — 双向对照实验、写合并设计、连接池
- [`修复.md`](修复.md) — 5 条记录（首条：mock 不 yield 导致测试假绿）
- 技术博客：[`docs/blog/04-ch7-db-并发存盘安全.md`](../docs/blog/04-ch7-db-并发存盘安全.md)
