-- test/bench_ecs.lua — ECS 性能基准（三层对比）
--
-- design.md Phase 3 验收标准：**C ECS 更新 1000 个 Entity < 1ms/帧**
--
-- 三层对比：
--   1. Lua ECS 通用 each()  —— 每次迭代构造参数表 + 多次哈希查找
--   2. Lua ECS 专用 tick()  —— 直接访问字段，无临时表
--   3. C ECS bench()        —— SoA 数组遍历，零 GC
--
-- 计时口径：
--   C 侧在 C 内部连续跑 ticks 帧并返回总纳秒（避免 Lua→C 调用开销被计入）
--   Lua 侧用 skynet.hpc()（纳秒，CLOCK_MONOTONIC）包住循环
--   两者同源，可直接比较

local skynet  = require "skynet"
local ecs_low = require "shared.ecs_low"
local ecs_c   = require "ecs_high"
local utils   = require "shared.utils"

local ENTITY = tonumber(os.getenv("CH6_ENTITY_COUNT")) or 1000
local TICKS  = tonumber(os.getenv("CH6_TICKS")) or 1000
local DT     = 0.016
local BOUND  = 1000.0

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

--- 构建 Lua ECS 世界
local function build_lua(n)
    local w = ecs_low.new()
    for i = 1, n do
        local e = w:create()
        w:add(e, "position", { x = (i % 1000) * 1.0, y = (i % 977) * 1.0 })
        w:add(e, "velocity", { x = 30.0, y = 17.0 })
        w:add(e, "health",   { hp = 50, maxhp = 100 })
    end
    return w
end

--- 构建 C ECS 世界
local function build_c(n)
    local w = ecs_c.new(n)
    for i = 1, n do
        w:add(i, (i % 1000) * 1.0, (i % 977) * 1.0, 30.0, 17.0, 50)
    end
    return w
end

--- Lua 通用 each 版本（同逻辑）
local function bench_lua_each(w, ticks)
    local t0 = skynet.hpc()
    for _ = 1, ticks do
        w:each({ "position", "velocity" }, function(_, pos, vel)
            local x = pos.x + vel.x * DT
            local y = pos.y + vel.y * DT
            if x < 0 then x = 0; vel.x = -vel.x
            elseif x > BOUND then x = BOUND; vel.x = -vel.x end
            if y < 0 then y = 0; vel.y = -vel.y
            elseif y > BOUND then y = BOUND; vel.y = -vel.y end
            pos.x = x; pos.y = y
        end)
    end
    return utils.us_between(t0, skynet.hpc())
end

--- Lua 专用 tick 版本
local function bench_lua_tick(w, ticks)
    local t0 = skynet.hpc()
    for _ = 1, ticks do
        w:tick(DT, BOUND)
    end
    return utils.us_between(t0, skynet.hpc())
end

local handlers = {}

function handlers.run()
    pass, fail = 0, 0
    out = {}

    emit(string.rep("=", 68))
    emit(string.format("ch6_ecs benchmark — entities=%d ticks=%d dt=%.3f",
        ENTITY, TICKS, DT))
    emit(string.rep("=", 68))

    -- ============================================================
    emit(string.format("\n=== Main: %d entities x %d ticks ===", ENTITY, TICKS))

    local lw_each = build_lua(ENTITY)
    local us_each = bench_lua_each(lw_each, TICKS)
    local ms_each = us_each / 1000
    emit(string.format("  -- Lua each()  : %10.2f ms  (%8.2f us/frame, %8.0f ns/entity)",
        ms_each, us_each / TICKS, us_each * 1000 / (TICKS * ENTITY)))

    local lw_tick = build_lua(ENTITY)
    local us_tick = bench_lua_tick(lw_tick, TICKS)
    local ms_tick = us_tick / 1000
    emit(string.format("  -- Lua tick()  : %10.2f ms  (%8.2f us/frame, %8.0f ns/entity)",
        ms_tick, us_tick / TICKS, us_tick * 1000 / (TICKS * ENTITY)))

    local cw = build_c(ENTITY)
    local ns_c = cw:bench(DT, BOUND, TICKS)     -- C 内部计时，返回纳秒
    local us_c = ns_c / 1000
    local ms_c = us_c / 1000
    emit(string.format("  -- C   bench() : %10.2f ms  (%8.2f us/frame, %8.0f ns/entity)",
        ms_c, us_c / TICKS, us_c * 1000 / (TICKS * ENTITY)))

    emit(string.format("  -- C vs Lua tick(): %.1fx faster", us_tick / us_c))
    emit(string.format("  -- C vs Lua each() : %.1fx faster", us_each / us_c))

    -- ============================================================
    -- design.md 验收：C ECS 1000 entity 更新 < 1ms/帧
    emit("\n=== Acceptance: C ECS 1000 entities < 1 ms/frame ===")
    local per_frame_us = us_c / TICKS
    emit(string.format("  -- per-frame: %.3f ms (limit 1.000 ms)", per_frame_us / 1000))
    check("B1 C ECS < 1ms/frame @1000 entities", per_frame_us < 1000,
        string.format("%.3f ms", per_frame_us / 1000))
    check("B2 C faster than Lua tick()", us_c < us_tick,
        string.format("C=%.1f Lua=%.1f", us_c, us_tick))
    check("B3 C faster than Lua each()", us_c < us_each,
        string.format("C=%.1f Lua=%.1f", us_c, us_each))
    check("B4 Lua tick() faster than each()", us_tick < us_each,
        string.format("tick=%.1f each=%.1f", us_tick, us_each))

    -- ============================================================
    emit("\n=== Scale: per-frame cost by entity count (ticks=100) ===")
    emit(string.format("  %10s  %14s  %14s  %10s", "entities", "Lua tick us/f", "C us/frame", "speedup"))
    local scale_results = {}
    for _, n in ipairs({ 100, 1000, 10000 }) do
        local l = build_lua(n)
        local u_l = bench_lua_tick(l, 100) / 100
        local c = build_c(n)
        local u_c = (c:bench(DT, BOUND, 100) / 1000) / 100
        emit(string.format("  %10d  %14.2f  %14.4f  %9.1fx",
            n, u_l, u_c, u_l / u_c))
        scale_results[n] = { lua = u_l, c = u_c }
    end

    -- 线性度：1000 → 10000 的每帧耗时应约 10 倍
    local r1 = scale_results[1000].c
    local r10 = scale_results[10000].c
    local linearity = r10 / r1
    emit(string.format("  -- C scaling 1000→10000: %.1fx (ideal 10x)", linearity))
    check("B5 C scales roughly linearly (5x~15x)", linearity > 5 and linearity < 15,
        string.format("%.1fx", linearity))

    -- ============================================================
    -- 跨语言调用开销：C 内部循环 vs Lua 逐帧调用
    -- 实践意义：若调用开销占比高，应把多个 system 合并成一次 C 调用
    emit("\n=== Call overhead: C-internal loop vs per-frame Lua→C call ===")
    local cw2 = build_c(ENTITY)
    local ns_internal = cw2:bench(DT, BOUND, TICKS)          -- C 内部连续 tick
    local t_ext = skynet.hpc()
    for _ = 1, TICKS do
        cw2:update(DT, BOUND)                                 -- 每帧一次 Lua→C
    end
    local us_external = utils.us_between(t_ext, skynet.hpc())
    local us_internal = ns_internal / 1000
    emit(string.format("  -- C-internal loop : %8.2f ms (%8.3f us/frame)",
        us_internal / 1000, us_internal / TICKS))
    emit(string.format("  -- per-frame call  : %8.2f ms (%8.3f us/frame)",
        us_external / 1000, us_external / TICKS))
    emit(string.format("  -- per-call overhead: %.3f us (+%.1f%%)",
        (us_external - us_internal) / TICKS,
        (us_external / us_internal - 1) * 100))

    -- ============================================================
    -- 数据回传成本：把 C 里的实体数据读到 Lua
    -- 实践意义：C ECS 的快，前提是"数据留在 C 里"
    emit("\n=== Data crossing cost: reading entities back into Lua ===")
    local cw3 = build_c(ENTITY)
    local t_r = skynet.hpc()
    local acc = 0
    for i = 1, ENTITY do
        local x = cw3:get(i)
        acc = acc + x
    end
    local us_read = utils.us_between(t_r, skynet.hpc())
    emit(string.format("  -- read %d entities : %8.2f us (%.3f us/entity)",
        ENTITY, us_read, us_read / ENTITY))
    emit(string.format("  -- vs one C frame    : %8.3f us", us_internal / TICKS))
    emit(string.format("  -- ratio: reading ALL entities costs %.0fx one frame",
        us_read / (us_internal / TICKS)))
    check("B6 cross-border read is >10x a full frame",
        us_read > (us_internal / TICKS) * 10,
        string.format("%.0fx", us_read / (us_internal / TICKS)))
    emit(string.format("  -- (sanity acc: %.0f)", acc))

    emit(string.rep("=", 68))
    emit(string.format("  Subtotal: %d PASS, %d FAIL", pass, fail))
    emit(string.rep("=", 68))

    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("bench_ecs", handlers)

return handlers
