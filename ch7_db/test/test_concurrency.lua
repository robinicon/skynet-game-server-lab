-- test/test_concurrency.lua — 并发存盘安全测试（含对照实验）
--
-- design.md 验收：
--   1. 同一 Agent 并发存盘 → 结果一致，无数据损坏
--   2. Agent 退出时同步存盘 → 数据完整落盘
--
-- 核心是**对照实验**：
--   对照组 —— 不经 queue，直接并发"读-改-写"（模拟裸用数据库）
--   实验组 —— 经 db 服务的 incr_hp（每个 uid 一个 skynet.queue）
--   若对照组没有丢失更新，说明 mock 驱动没注入 yield，测试是假绿的。
--   所以 C1 必须**失败**（观测到丢失更新）才证明测试有效。

local skynet  = require "skynet"
local driver  = require "shared.db_driver"
local utils   = require "shared.utils"

local N = tonumber(os.getenv("CH7_CONCURRENCY_N")) or 20

local pass, fail = 0, 0
local out = {}

local function emit(s)
    out[#out + 1] = s
    io.write(s .. "\n")
end

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        emit(string.format("  PASS  %s", name))
    else
        fail = fail + 1
        emit(string.format("  FAIL  %s  %s", name, tostring(detail)))
    end
end

--- 等待 N 个并发任务完成（带超时上限，避免永久挂死）
local function wait_done(counter_ref, n, limit_ticks)
    local waited = 0
    while counter_ref.done < n and waited < (limit_ticks or 2000) do
        skynet.sleep(1)
        waited = waited + 1
    end
    return counter_ref.done >= n
end

local handlers = {}

function handlers.run(db)
    pass, fail = 0, 0
    out = {}

    if not db then
        emit("ERROR: db addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR: no db" }
    end

    emit(string.rep("=", 66))
    emit(string.format("ch7_db concurrency — N=%d", N))
    emit(string.rep("=", 66))

    -- ============================================================
    -- 对照组：无 queue 保护，直接并发读-改-写
    -- ============================================================
    emit(string.format("\n=== C1: control group — %d concurrent read-modify-write, NO queue ===", N))
    local drv = driver.new_memory({ latency = 1 })     -- 每次操作 yield 10ms
    local ref_u = { done = 0 }
    local t_u0 = skynet.hpc()                          -- 对照组同样计时，便于与 C2 同口径对比
    for _ = 1, N do
        skynet.fork(function()
            local row = drv:load_role(9001)            -- yield #1
            local hp = (row and row.hp or 0) + 1
            drv:save_role(9001, { hp = hp })           -- yield #2
            ref_u.done = ref_u.done + 1
        end)
    end
    local ok_u = wait_done(ref_u, N)
    local ms_u = (skynet.hpc() - t_u0) / 1e6
    local hp_u = drv:load_role(9001).hp
    emit(string.format("  -- completed=%d/%d in %.1f ms, final hp=%d (expected %d if safe)",
        ref_u.done, N, ms_u, hp_u, N))
    emit(string.format("  -- lost updates: %d", N - hp_u))
    check("C1.1 control group completed", ok_u and ref_u.done == N, ref_u.done)
    -- 关键断言：对照组**必须**丢失更新，否则说明 mock 没有 yield，测试无效
    check("C1.2 control group LOSES updates (proves the test is meaningful)",
        hp_u < N, string.format("hp=%d N=%d", hp_u, N))

    -- ============================================================
    -- 实验组：db 服务内每个 uid 一个 skynet.queue
    -- ============================================================
    emit(string.format("\n=== C2: experiment group — %d concurrent incr_hp WITH queue ===", N))
    skynet.call(db, "lua", "reset")
    skynet.call(db, "lua", "save_sync", 9002, { hp = 0 })

    local ref_s = { done = 0 }
    local t0 = skynet.hpc()
    for _ = 1, N do
        skynet.fork(function()
            skynet.call(db, "lua", "incr_hp", 9002)
            ref_s.done = ref_s.done + 1
        end)
    end
    local ok_s = wait_done(ref_s, N)
    local elapsed_ms = utils.us_between(t0, skynet.hpc()) / 1000
    local row_s = skynet.call(db, "lua", "load", 9002)
    local hp_s = row_s and row_s.hp or -1
    emit(string.format("  -- completed=%d/%d in %.1f ms, final hp=%d (expected %d)",
        ref_s.done, N, elapsed_ms, hp_s, N))
    check("C2.1 experiment group completed", ok_s and ref_s.done == N, ref_s.done)
    check("C2.2 NO lost updates with queue", hp_s == N, string.format("hp=%d expected=%d", hp_s, N))
    check("C2.3 serialized (took longer than one op)", elapsed_ms > 10,
        string.format("%.1f ms", elapsed_ms))

    emit(string.format("\n  -- comparison: unsafe=%d  safe=%d  (ideal %d)", hp_u, hp_s, N))

    -- ============================================================
    emit("\n=== C3: async/sync ordering guarantee ===")
    skynet.call(db, "lua", "reset")
    local uid3 = 9003
    for i = 1, 10 do
        -- send = 异步，不等待；但 db 侧按 uid 串行，顺序即到达顺序
        skynet.send(db, "lua", "save_async", uid3, { hp = i })
    end
    -- call = 同步，排队在最后，返回时前面的异步一定已完成
    skynet.call(db, "lua", "save_sync", uid3, { hp = 999 })
    local row3 = skynet.call(db, "lua", "load", uid3)
    check("C3.1 sync after asyncs is the final state", row3 and row3.hp == 999,
        row3 and row3.hp)

    -- ============================================================
    emit("\n=== C4: agent exit saves synchronously ===")
    skynet.call(db, "lua", "reset")
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", 9004, db)
    skynet.call(agent, "lua", "modify", -25, 777)
    -- 先发起异步存盘，再退出：退出流程必须等异步归零 + 补一次同步
    skynet.call(agent, "lua", "save_async")
    local ok4 = skynet.call(agent, "lua", "exit")
    check("C4.1 exit returned ok", ok4 == true, tostring(ok4))
    local row4 = skynet.call(db, "lua", "load", 9004)
    check("C4.2 final state persisted", row4 and row4.hp == 75 and row4.gold == 777,
        row4 and string.format("hp=%s gold=%s", tostring(row4.hp), tostring(row4.gold)))

    -- ============================================================
    emit("\n=== C5: isolation — slow uid must not block others ===")
    local slow_uid = 100
    skynet.fork(function()
        skynet.call(db, "lua", "slow_echo", slow_uid, 30)   -- 占连接 300ms
    end)
    skynet.sleep(2)                                          -- 等它拿到连接
    local t5 = skynet.hpc()
    skynet.call(db, "lua", "load", 200)                      -- 另一个 uid
    local us5 = utils.us_between(t5, skynet.hpc())
    emit(string.format("  -- other uid load took %.2f ms while slow uid is running", us5 / 1000))
    check("C5.1 other uid not blocked (< 100ms)", us5 < 100000,
        string.format("%.2f ms", us5 / 1000))

    -- ============================================================
    emit("\n=== C6: pool grows under concurrent load ===")
    local st_before = skynet.call(db, "lua", "stats")
    local ref6 = { done = 0 }
    for _ = 1, 20 do
        skynet.fork(function()
            skynet.call(db, "lua", "slow_echo", 300 + (ref6.done % 8), 2)
            ref6.done = ref6.done + 1
        end)
    end
    wait_done(ref6, 20)
    local st_after = skynet.call(db, "lua", "stats")
    emit(string.format("  -- pool: total %d → %d (min=%d max=%d hard_max=%d)",
        st_before.pool.total, st_after.pool.total,
        st_after.pool.min, st_after.pool.max, st_after.pool.hard_max))
    check("C6.1 pool grew beyond min under load", st_after.pool.total > st_after.pool.min,
        string.format("total=%d min=%d", st_after.pool.total, st_after.pool.min))
    check("C6.2 pool within hard_max", st_after.pool.total <= st_after.pool.hard_max,
        st_after.pool.total)
    check("C6.3 no waiters left", st_after.pool.waiting == 0, st_after.pool.waiting)

    -- ============================================================
    -- 写合并：串行化保证了正确性但拖慢了延迟，用合并把写次数降下来
    emit("\n=== C7: write coalescing ===")
    local st_b7 = skynet.call(db, "lua", "stats")
    local uid7, M7 = 9005, 100
    for i = 1, M7 do
        skynet.send(db, "lua", "save_async", uid7, { hp = i })
    end
    skynet.sleep(20)                       -- 等合并窗口与 flush 完成
    local row7 = skynet.call(db, "lua", "load", uid7)
    local st_a7 = skynet.call(db, "lua", "stats")
    local writes7 = st_a7.io.writes - st_b7.io.writes
    emit(string.format("  -- %d async saves → %d actual DB writes (merged %d, flushes %d)",
        M7, writes7, st_a7.io.merged - st_b7.io.merged, st_a7.io.flushes - st_b7.io.flushes))
    check("C7.1 final state equals last write", row7 and row7.hp == M7, row7 and row7.hp)
    check("C7.2 write count reduced by >50%", writes7 <= M7 / 2,
        string.format("%d writes for %d saves", writes7, M7))

    emit(string.rep("=", 66))
    emit(string.format("  Subtotal: %d PASS, %d FAIL", pass, fail))
    emit(string.rep("=", 66))

    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_concurrency", handlers)

return handlers
