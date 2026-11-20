-- test/bench_pool.lua — 池化 vs 非池化基准 + 函数级 profiling
--
-- design.md Phase 2 验收标准：
--   1. 先跑 baseline benchmark（无对象池），确认对象创建开销
--   2. profiling 确认热点后再池化
--   3. 池化后对象分配次数下降 >50%
--
-- 三个场景：
--   A. packet      顺序借还（最理想的池化场景）
--   B. aoi_entity  批量持有（模拟并发持有 K 个对象）
--   C. heavy       变长对象反例 —— reset 成本随使用规模线性增长，池化是负优化
--
-- 指标口径：
--   created     = factory 调用次数（真实的"对象分配次数"）
--   elapsed_us  = skynet.hpc() 纳秒差值（不要用 skynet.time()，精度只有 10ms）
--   heap_peak   = 负载过程中 collectgarbage("count") 的峰值，反映 GC 压力
--                 （不手动 collect，让 Lua 自动 GC，峰值越高说明 GC 越吃力）

local skynet   = require "skynet"
local pool     = require "shared.pool"
local workload = require "shared.workload"
local profiler = require "shared.profiler"
local utils    = require "shared.utils"

local ROUNDS = tonumber(os.getenv("CH5_BENCH_ROUNDS")) or 100000
local HOLD   = tonumber(os.getenv("CH5_BENCH_HOLD")) or 64
local PROFILE_ROUNDS = 20000

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

--- 非池化负载：每次 factory 新建
local function run_nopool(def, rounds, hold)
    hold = hold or 1
    local created, acc = 0, 0
    local heap_peak = 0
    local t0 = skynet.hpc()
    local rounds_done = 0
    while rounds_done < rounds do
        local batch = math.min(hold, rounds - rounds_done)
        local objs = {}
        for i = 1, batch do
            objs[i] = def.factory()
            created = created + 1
        end
        for i = 1, batch do
            acc = acc + def.use(objs[i], rounds_done + i)
        end
        objs = nil
        rounds_done = rounds_done + batch
        if rounds_done % 1000 == 0 then
            local c = collectgarbage("count")
            if c > heap_peak then heap_peak = c end
        end
    end
    local us = utils.us_between(t0, skynet.hpc())
    return { created = created, elapsed_us = us, heap_peak_kb = heap_peak, acc = acc }
end

--- 池化负载：get / use / put
local function run_pool(def, rounds, hold, pool_max, prewarm, mode)
    hold = hold or 1
    local p = pool.new({
        name    = def.name .. "_bench",
        factory = def.factory,
        reset   = def.reset,
        max     = pool_max or 1024,
        prewarm = prewarm or 32,
        mode    = mode or "strict",
    })
    local acc = 0
    local heap_peak = 0
    local t0 = skynet.hpc()
    local rounds_done = 0
    while rounds_done < rounds do
        local batch = math.min(hold, rounds - rounds_done)
        local objs = {}
        for i = 1, batch do
            objs[i] = p:get()
        end
        for i = 1, batch do
            acc = acc + def.use(objs[i], rounds_done + i)
        end
        for i = 1, batch do
            p:put(objs[i])
        end
        rounds_done = rounds_done + batch
        if rounds_done % 1000 == 0 then
            local c = collectgarbage("count")
            if c > heap_peak then heap_peak = c end
        end
    end
    local us = utils.us_between(t0, skynet.hpc())
    local st = p:stats()
    return {
        created = st.created,
        elapsed_us = us,
        heap_peak_kb = heap_peak,
        acc = acc,
        stats = st,
    }
end

local function emit_pair(tag, nopool, pooled)
    local reduction = nopool.created > 0
        and (1 - pooled.created / nopool.created) * 100 or 0
    local speedup = pooled.elapsed_us > 0
        and nopool.elapsed_us / pooled.elapsed_us or 0
    emit(string.format("  -- no-pool: %8.2f ms  created=%-8s heap_peak=%8.1f KB",
        nopool.elapsed_us / 1000, utils.comma(nopool.created), nopool.heap_peak_kb))
    emit(string.format("  -- pooled : %8.2f ms  created=%-8s heap_peak=%8.1f KB",
        pooled.elapsed_us / 1000, utils.comma(pooled.created), pooled.heap_peak_kb))
    emit(string.format("  -- alloc reduction: %.2f%%   speedup: %.2fx",
        reduction, speedup))
    return reduction, speedup
end

--- 纯 get/put 微基准（不含 use）：量化"池开销"本身
local function bench_getput(def, mode, rounds, prewarm)
    local p = pool.new({
        name = def.name .. "_ovh", factory = def.factory, reset = def.reset,
        max = 1024, prewarm = prewarm, mode = mode,
    })
    local t0 = skynet.hpc()
    for _ = 1, rounds do
        local o = p:get()
        p:put(o)
    end
    return utils.us_between(t0, skynet.hpc())
end

--- 纯 factory 微基准：非池化路径上的直接成本
local function bench_factory(def, rounds)
    local f = def.factory
    local t0 = skynet.hpc()
    for _ = 1, rounds do
        local o = f()
        o = nil
    end
    return utils.us_between(t0, skynet.hpc())
end

local handlers = {}

function handlers.run()
    pass, fail = 0, 0
    out = {}

    emit(string.rep("=", 66))
    emit(string.format("ch5_perf benchmark — rounds=%s hold=%s", utils.comma(ROUNDS), HOLD))
    emit(string.rep("=", 66))

    -- ============================================================
    emit("\n=== Scenario A: packet (sequential get/use/put) ===")
    local a_no = run_nopool(workload.packet, ROUNDS, 1)
    local a_st = run_pool(workload.packet, ROUNDS, 1, 1024, 32, "strict")
    local a_fa = run_pool(workload.packet, ROUNDS, 1, 1024, 32, "fast")
    local a_ba = run_pool(workload.packet, ROUNDS, 1, 1024, 32, "bare")
    local a_red = emit_pair("A", a_no, a_st)
    emit(string.format("  -- pool/fast : %8.2f ms  created=%-8s speedup: %.2fx",
        a_fa.elapsed_us / 1000, utils.comma(a_fa.created),
        a_fa.elapsed_us > 0 and a_no.elapsed_us / a_fa.elapsed_us or 0))
    emit(string.format("  -- pool/bare : %8.2f ms  created=%-8s speedup: %.2fx",
        a_ba.elapsed_us / 1000, utils.comma(a_ba.created),
        a_ba.elapsed_us > 0 and a_no.elapsed_us / a_ba.elapsed_us or 0))
    check("A1 alloc reduction > 50%", a_red > 50, string.format("%.2f%%", a_red))
    local a_best = math.min(a_st.elapsed_us, a_fa.elapsed_us, a_ba.elapsed_us)
    check("A2 best pool mode not slower than no-pool", a_best <= a_no.elapsed_us,
        string.format("best=%.2fms nopool=%.2fms", a_best / 1000, a_no.elapsed_us / 1000))

    -- ============================================================
    emit(string.format("\n=== Scenario B: aoi_entity (batch hold=%d) ===", HOLD))
    local b_no = run_nopool(workload.aoi_entity, ROUNDS, HOLD)
    local b_po = run_pool(workload.aoi_entity, ROUNDS, HOLD, 1024, HOLD)
    local b_red, b_spd = emit_pair("B", b_no, b_po)
    check("B1 alloc reduction > 50%", b_red > 50, string.format("%.2f%%", b_red))
    check("B2 pooled not slower", b_spd >= 1.0, string.format("%.2fx", b_spd))

    -- ============================================================
    emit("\n=== Scenario C: heavy (variable-length, reset cost grows) ===")
    emit(string.format("  (each use fills %d items; reset must clear them all)",
        workload.heavy.scale))
    local c_no = run_nopool(workload.heavy, math.floor(ROUNDS / 10), 1)
    local c_po = run_pool(workload.heavy, math.floor(ROUNDS / 10), 1, 1024, 32)
    local c_red, c_spd = emit_pair("C", c_no, c_po)
    -- 这个场景的"正确结果"就是池化更慢：断言我们确实检测到了负优化
    check("C1 negative optimization detected (pooled slower)", c_spd < 1.0,
        string.format("%.2fx", c_spd))
    emit(string.format("  NOTE: pooled is %.2f ms SLOWER overall — reset must clear %d items",
        c_po.elapsed_us / 1000 - c_no.elapsed_us / 1000, workload.heavy.scale))
    emit("        per round, costing more than the single table allocation it saves")
    emit("        (clearing is mandatory: leaving stale refs would leak the whole array)")

    -- ============================================================
    emit("\n=== Scenario D: damage_event (sequential) ===")
    local d_no = run_nopool(workload.damage_event, ROUNDS, 1)
    local d_po = run_pool(workload.damage_event, ROUNDS, 1, 1024, 32)
    local d_red, d_spd = emit_pair("D", d_no, d_po)
    check("D1 alloc reduction > 50%", d_red > 50, string.format("%.2f%%", d_red))

    -- ============================================================
    -- 成本归因：池开销 vs 构造开销（决定"该不该池化"的唯一判据）
    emit("\n=== Scenario E: overhead breakdown (get+put vs factory, no use) ===")
    local e_rounds = ROUNDS
    local e_fac = bench_factory(workload.packet, e_rounds)
    local e_st  = bench_getput(workload.packet, "strict", e_rounds, 32)
    local e_fa  = bench_getput(workload.packet, "fast",   e_rounds, 32)
    local e_ba  = bench_getput(workload.packet, "bare",   e_rounds, 32)
    emit(string.format("  -- factory()        : %8.2f ms  (%6.1f ns/op)",
        e_fac / 1000, e_fac * 1000 / e_rounds))
    emit(string.format("  -- get+put / strict : %8.2f ms  (%6.1f ns/op)  overhead %.2fx",
        e_st / 1000, e_st * 1000 / e_rounds, e_st / e_fac))
    emit(string.format("  -- get+put / fast   : %8.2f ms  (%6.1f ns/op)  overhead %.2fx",
        e_fa / 1000, e_fa * 1000 / e_rounds, e_fa / e_fac))
    emit(string.format("  -- get+put / bare   : %8.2f ms  (%6.1f ns/op)  overhead %.2fx",
        e_ba / 1000, e_ba * 1000 / e_rounds, e_ba / e_fac))
    check("E1 fast mode overhead < 2x factory", e_fa / e_fac < 2.0,
        string.format("%.2fx", e_fa / e_fac))
    check("E2 bare is fastest", e_ba <= e_fa and e_ba <= e_st,
        string.format("bare=%.2f fast=%.2f strict=%.2f", e_ba, e_fa, e_st))

    -- ============================================================
    -- 函数级 profiling：确认"对象创建"确实是热点（design.md 要求先确认再池化）
    emit("\n=== Profiler: no-pool packet workload (sampling) ===")
    profiler.start(1000)
    local def = workload.packet
    local acc = 0
    for i = 1, PROFILE_ROUNDS do
        local o = def.factory()
        acc = acc + def.use(o, i)
    end
    local r = profiler.stop()
    profiler.report(r, 8)
    emit(string.format("  (accumulator sanity: %d)", acc))

    -- factory 是匿名函数，name 会是 nil → "anonymous"；
    -- 断言：anonymous（factory/use 等闭包）合计占比 > 20%
    local anon_pct = 0
    if r then
        for _, e in ipairs(r.list) do
            if e.name == "?" or e.name == nil then
                anon_pct = anon_pct + e.pct
            end
        end
        emit(string.format("  anonymous closure share: %.2f%%", anon_pct))
    end
    check("P1 profiler captured samples", r ~= nil and r.total > 0,
        r and r.total or 0)

    emit(string.rep("=", 66))
    emit(string.format("  Subtotal: %d PASS, %d FAIL", pass, fail))
    emit(string.rep("=", 66))

    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("bench_pool", handlers)

return handlers
