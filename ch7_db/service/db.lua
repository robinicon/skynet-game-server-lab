-- service/db.lua — 独立 DB 服务
--
-- design.md Phase 4 的四条要求：
--   1. 单服务汇聚所有持久化请求          → 本服务
--   2. 连接池统一管理，按负载动态调整     → shared/connpool.lua
--   3. 异步存盘 skynet.send / 同步 skynet.call → save_async / save_sync
--   4. 用 skynet.queue 串行化同一 Agent 的存盘请求 → get_q(uid)
--
-- 为什么必须串行化同一 Agent 的请求：
--   存盘通常是"读-改-写"三步，每步都会因网络往返而 yield。
--   若同一 uid 的两个请求并发：
--       A: load → hp=10
--       B: load → hp=10      ← 读到同样的旧值
--       A: save hp=11
--       B: save hp=11        ← A 的更新被覆盖
--   结果：两次 +1 只生效一次（丢失更新）。
--   queue 保证同一 uid 的请求严格串行，代价是该 uid 的存盘不能并发。
--
-- ⚠️ CH7_NO_QUEUE=1 可关闭串行化，仅用于对照实验（演示丢失更新）。

local skynet   = require "skynet"
local queue    = require "skynet.queue"
local service  = require "shared.service"
local driver   = require "shared.db_driver"
local connpool = require "shared.connpool"

local drv  = nil
local pool = nil
local uid_queues = {}

-- 对照实验开关：关闭后并发存盘会丢失更新（见 test/test_concurrency.lua）
local NO_QUEUE = os.getenv("CH7_NO_QUEUE") == "1"

local function get_q(uid)
    local q = uid_queues[uid]
    if not q then
        q = queue()
        uid_queues[uid] = q
    end
    return q
end

--- 在串行队列内执行（或按开关直接执行）
-- 注意：skynet.queue 的 q(f) 会在**当前协程**执行 f，
-- f 内部的 yield 只挂起当前协程，恢复后继续 —— 所以 q(f) 返回时 f 已完成，
-- 天然具备"同步等待"语义，不需要额外的 done 标志。
local function serial(uid, f)
    if NO_QUEUE then
        return f()
    end
    local q = get_q(uid)
    return q(f)
end

local handlers = {}

function handlers.init(opts)
    opts = opts or {}
    local kind = opts.kind or os.getenv("CH7_DB_DRIVER") or "memory"
    drv = driver.create({
        kind     = kind,
        latency  = opts.latency,
        slow_uid = opts.slow_uid,
        -- mysql 选项
        host     = opts.host, port = opts.port,
        user     = opts.user, password = opts.password,
        database = opts.database,
    })
    if not drv then
        return false, "driver create failed"
    end

    pool = connpool.new({
        name     = "db",
        min      = opts.pool_min or 1,
        max      = opts.pool_max or 8,
        hard_max = opts.pool_hard_max or 32,
        factory  = function()
            return drv:new_conn()
        end,
        closer   = function(conn)
            if conn.close then conn:close() end
        end,
    })
    return true
end

-- ========== 写合并（write coalescing）==========
-- 串行化保证正确，但代价是延迟（历史实测：无 queue ~28ms / 有 queue ~408ms，约 14 倍；
-- 具体毫秒数随环境波动，以当次日志为准）。
-- 补偿手段：同一 uid 的**异步**存盘不必各自写一次，合并成最后一次的状态即可。
--
--   100 次 save_async(hp=1..100)  →  实际只需 1 次落盘（hp=100）
--
-- 安全性：
--   - save_sync 会接管 pending 并同步落盘，flush 协程醒来发现 pending 为空则跳过
--   - flush 与 save_sync 走同一条 serial(uid) 队列，顺序仍然有保证
--   - 合并只针对"覆盖式写入"；读-改-写（incr_hp）不能合并，必须串行

local pending  = {}     -- uid → 待写入的最新数据
local flushing = {}     -- uid → 是否有 flush 协程在途
local FLUSH_DELAY = tonumber(os.getenv("CH7_FLUSH_DELAY")) or 1
local NO_COALESCE = os.getenv("CH7_NO_COALESCE") == "1"

local stat = { writes = 0, merged = 0, flushes = 0 }

local function do_write(uid, data)
    stat.writes = stat.writes + 1
    return serial(uid, function()
        local conn = pool:acquire()
        local ok = conn:save_role(uid, data)
        pool:release(conn)
        return ok
    end)
end

--- 异步存盘（常规路径）：调用方不等待结果
function handlers.save_async(uid, data)
    if NO_COALESCE then
        return do_write(uid, data)
    end

    local p = pending[uid]
    if p then
        for k, v in pairs(data) do p[k] = v end
        stat.merged = stat.merged + 1
    else
        pending[uid] = data
    end

    if flushing[uid] then
        return true          -- 已有 flush 在途，它会带走最新数据
    end

    flushing[uid] = true
    skynet.fork(function()
        skynet.sleep(FLUSH_DELAY)          -- 合并窗口
        local d = pending[uid]
        pending[uid] = nil
        flushing[uid] = nil
        if d then
            stat.flushes = stat.flushes + 1
            do_write(uid, d)
        end
    end)
    return true
end

--- 同步存盘（退出/关键节点）：调用方阻塞到落盘完成
-- 会接管 pending 中未落盘的数据，保证"之前的所有修改 + 本次"一起落盘
function handlers.save_sync(uid, data)
    local p = pending[uid]
    if p then
        for k, v in pairs(data) do p[k] = v end
        data = p
        pending[uid] = nil
    end
    return do_write(uid, data)
end

function handlers.load(uid)
    return serial(uid, function()
        local conn = pool:acquire()
        local row = conn:load_role(uid)
        pool:release(conn)
        return row
    end)
end

function handlers.delete(uid)
    return serial(uid, function()
        local conn = pool:acquire()
        local ok = conn:delete_role(uid)
        pool:release(conn)
        return ok
    end)
end

--- 读-改-写（+1）：并发安全的试金石
-- 两次 yield 之间若不串行化，并发调用会丢失更新。
function handlers.incr_hp(uid)
    return serial(uid, function()
        local conn = pool:acquire()
        local row = conn:load_role(uid)                 -- yield #1
        local hp = (row and row.hp or 0) + 1
        conn:save_role(uid, { hp = hp })                -- yield #2
        pool:release(conn)
        return hp
    end)
end

--- 慢操作：占用连接较长时间，用于验证连接池与隔离性
function handlers.slow_echo(uid, ticks)
    return serial(uid, function()
        local conn = pool:acquire()
        skynet.sleep(tonumber(ticks) or 1)
        pool:release(conn)
        return true
    end)
end

function handlers.stats()
    return {
        driver   = drv and drv.kind or "none",
        no_queue = NO_QUEUE,
        coalesce = not NO_COALESCE,
        pool     = pool and pool:stats() or nil,
        queues   = (function()
            local n = 0
            for _ in pairs(uid_queues) do n = n + 1 end
            return n
        end)(),
        io       = { writes = stat.writes, merged = stat.merged, flushes = stat.flushes },
    }
end

function handlers.driver_stats()
    return drv and drv.stats or nil
end

--- 测试用：清库（memory 清内存表；mysql 下发 DELETE FROM roles）
function handlers.reset()
    if not drv then return true end
    if type(drv.reset) == "function" then
        return drv:reset()          -- mysql 驱动
    end
    if drv.rows then
        drv.rows = {}
        drv.stats = { load = 0, save = 0, yield = 0 }
    end
    return true
end

service.start("db", handlers, {
    on_init = function()
        skynet.error("[db] service created (waiting for init)")
    end,
})
