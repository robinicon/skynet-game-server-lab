-- shared/dist_call.lua — 跨节点调用封装：超时 + 熔断 + 计数
--
-- 为什么要包一层？裸 cluster.call 有三个致命问题：
--
--  1) 会永久阻塞。
--     两种情况：
--       a) 目标服务不返回（假死 / 死循环 / 异常分支漏了 skynet.ret）
--          → clustersender 在 wait_for_response 里 skynet.wait() 等不到响应。
--       b) __nowaiting=false 且节点名未解析
--          → clusterd 在 open_channel 里 skynet.wait()；注意阻塞的是 clusterd
--            自己的 dispatch 协程，等于整个进程的跨节点调用一起挂。
--     这两种情况调用方既拿不到超时也拿不到错误，服务被静默拖死。
--
--  2) 故障期间会持续堆积。
--     每来一个请求就发起一次「会阻塞的调用」，连接/协程/内存全部堆积 → 雪崩。
--     这里加了最简熔断：连续失败达阈值即熔断，冷却期内直接 fail-fast。
--
--  3) 返回值语义混乱。
--     cluster.call 在网络层失败时返回 **单值 false**（不抛异常）；
--     远端业务返回 (false, "bad_token") 时返回 **两个值**。
--     `local ok, err = cluster.call(...)` 这种写法会把业务结果错绑到 err 上。
--     约定：所有跨节点接口必须返回至少 2 个值，第一个是业务 ok。
--     于是 pack.n == 1 and pack[1] == false 唯一地表示「网络/框架层失败」。
--
-- 统一返回：ok, pack
--   ok == false → 调用没成功，pack 是错误字符串（timeout / error:.. / circuit_open / remote_error）
--   ok == true  → pack 是远端返回值的 table.pack 结果，业务结果在 pack[1]
--
-- 局限（必须知道）：
--   超时只是「放弃等待」，既不能取消已发出的请求，也不能回收被阻塞的协程。
--   被放弃的协程会计入 leaked。生产环境必须配合节点健康探测 + 熔断，
--   必要时靠 watchdog 重启进程。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local M = {}

local OPTS = {
    timeout   = tonumber(os.getenv("CH10_CALL_TIMEOUT")) or 100,  -- cs（1 cs = 10ms）
    threshold = tonumber(os.getenv("CH10_CB_THRESHOLD")) or 3,    -- 连续失败几次后熔断
    cooldown  = tonumber(os.getenv("CH10_CB_COOLDOWN"))  or 300,  -- 熔断持续 cs
}

M.OPTS = OPTS

local breaker = {}   -- node -> { st = closed|open|half_open, fails, open_until }
local stats   = {}   -- node -> 计数表

local function bget(node)
    local b = breaker[node]
    if not b then
        b = { st = "closed", fails = 0, open_until = 0 }
        breaker[node] = b
    end
    return b
end

local function sget(node)
    local s = stats[node]
    if not s then
        s = {
            total = 0, ok = 0, fail = 0,
            timeout = 0, remote_error = 0, error = 0,
            short_circuit = 0, leaked = 0, send = 0,
            cost_ns = 0,
        }
        stats[node] = s
    end
    return s
end

-- 在超时保护下执行一次 cluster.call
local function timed_call(node, addr, timeout_cs, ...)
    local co   = coroutine.running()
    local box  = { st = "running" }        -- running | done | timeout
    local args = table.pack(...)

    skynet.fork(function()
        local ok, pack = pcall(function()
            return table.pack(cluster.call(node, addr, table.unpack(args, 1, args.n)))
        end)
        if box.st ~= "running" then
            -- 调用方已经放弃等待：结果丢弃。
            -- 已发出的请求无法取消，这个协程会一直卡在 wait_for_response 上。
            sget(node).leaked = sget(node).leaked + 1
            return
        end
        box.st, box.ok, box.res = "done", ok, pack
        skynet.wakeup(co)
    end)

    skynet.timeout(timeout_cs, function()
        if box.st ~= "running" then return end
        box.st = "timeout"
        skynet.wakeup(co)
    end)

    skynet.wait(co)

    if box.st == "timeout" then
        return false, "timeout"
    end
    if not box.ok then
        -- 远端抛异常 / 节点名 absent 等，cluster.call 会 raise
        return false, "error:" .. tostring(box.res)
    end

    local r = box.res
    if r.n == 1 and r[1] == false then
        -- 网络层失败：cluster.call 只返回单值 false
        return false, "remote_error"
    end
    return true, r
end

-- 带熔断的跨节点 call
function M.call_ex(node, addr, timeout_cs, ...)
    local s = sget(node)
    local b = bget(node)
    s.total = s.total + 1

    if b.st == "open" then
        if skynet.now() < b.open_until then
            s.short_circuit = s.short_circuit + 1
            return false, "circuit_open"
        end
        -- 冷却期已过：转入半开，放行一次探测
        b.st = "half_open"
    end

    local t0 = skynet.hpc()
    local ok, res = timed_call(node, addr, timeout_cs, ...)
    s.cost_ns = s.cost_ns + (skynet.hpc() - t0)

    if ok then
        s.ok = s.ok + 1
        b.fails, b.st, b.open_until = 0, "closed", 0
        return true, res
    end

    s.fail = s.fail + 1
    if res == "timeout" then
        s.timeout = s.timeout + 1
    elseif res == "remote_error" then
        s.remote_error = s.remote_error + 1
    elseif res == "circuit_open" then
        -- 不会走到这里
    else
        s.error = s.error + 1
    end

    b.fails = b.fails + 1
    if b.fails >= OPTS.threshold then
        b.st         = "open"
        b.open_until = skynet.now() + OPTS.cooldown
        b.fails      = 0
    end
    return false, res
end

function M.call(node, addr, ...)
    return M.call_ex(node, addr, OPTS.timeout, ...)
end

-- 启动期探测：绕过熔断，也不计入失败统计。
-- （否则节点还没起来时的探测失败会直接把熔断器打 open，之后全部 fail-fast）
function M.probe(node, addr, ...)
    return timed_call(node, addr, OPTS.timeout, ...)
end

-- 高频路径：只发不等
function M.send(node, addr, ...)
    sget(node).send = sget(node).send + 1
    cluster.send(node, addr, ...)
end

function M.stats(node)
    if node then
        local s = stats[node]
        if not s then return nil end
        local t = {}
        for k, v in pairs(s) do t[k] = v end
        return t
    end
    local all = {}
    for k, v in pairs(stats) do
        all[k] = {}
        for k2, v2 in pairs(v) do all[k][k2] = v2 end
    end
    return all
end

function M.breaker(node)
    local b = bget(node)
    return { st = b.st, fails = b.fails, open_until = b.open_until }
end

function M.reset()
    breaker = {}
    stats   = {}
end

return M
