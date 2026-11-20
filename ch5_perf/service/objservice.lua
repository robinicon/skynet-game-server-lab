-- service/objservice.lua — 业务对象服务（服务级 profiling 用）
--
-- 与 test/bench_pool.lua 的区别：
--   bench_pool 在本服务内直接跑，避免跨服务调用开销污染基准；
--   本服务演示的是**服务级**视角：用 skynet.stat("cpu") 观察
--   同一个服务在池化 / 非池化下的累计 CPU 消耗差异。
--
-- skynet 内置 profile 只提供这一层（累计 CPU 微秒），函数级热点要靠
-- shared/profiler.lua 的采样 profiler。两者配合才能定位到函数。

local skynet = require "skynet"
local service = require "shared.service"
local pool    = require "shared.pool"
local workload = require "shared.workload"

local p = nil   -- packet 池

local handlers = {}

--- 非池化：每次新建
function handlers.run_nopool(n)
    n = tonumber(n) or 10000
    local def = workload.packet
    local acc = 0
    for i = 1, n do
        local o = def.factory()
        acc = acc + def.use(o, i)
    end
    return acc
end

--- 池化：复用
function handlers.run_pool(n)
    n = tonumber(n) or 10000
    local def = workload.packet
    local acc = 0
    for i = 1, n do
        local o = p:get()
        acc = acc + def.use(o, i)
        p:put(o)
    end
    return acc
end

--- 服务级 CPU 快照（微秒）
function handlers.cpu()
    return tonumber(skynet.stat("cpu")) or 0
end

--- 重置统计
function handlers.reset_stat()
    return p:stats()
end

function handlers.pool_stats()
    return p:stats()
end

service.start("objservice", handlers, {
    on_init = function()
        local def = workload.packet
        p = pool.new({
            name    = def.name,
            factory = def.factory,
            reset   = def.reset,
            max     = 1024,
            prewarm = 32,
        })
        skynet.error(string.format("[objservice] packet pool prewarmed: %d", p:stats().size))
    end,
})
