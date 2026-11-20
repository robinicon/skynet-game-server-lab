-- test/test_pool.lua — 对象池正确性测试（18 用例）
--
-- 覆盖：生命周期 / 池满策略 / 误用检测 / 统计 / 泄漏 / 多池隔离

local pool       = require "shared.pool"
local workload   = require "shared.workload"
local error_code = require "shared.error_code"

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

local function mk(def, opts)
    opts = opts or {}
    return pool.new({
        name    = def.name,
        factory = def.factory,
        reset   = def.reset,
        max     = opts.max or 16,
        prewarm = opts.prewarm or 0,
    })
end

local handlers = {}

function handlers.run()
    pass, fail = 0, 0
    out = {}

    emit("=== T1: new + initial state ===")
    local p1 = mk(workload.packet, { max = 16 })
    local s1 = p1:stats()
    check("T1.1 size=0", s1.size == 0, s1.size)
    check("T1.2 created=0", s1.created == 0, s1.created)
    check("T1.3 max=16", s1.max == 16, s1.max)

    emit("=== T2: get on empty pool triggers factory ===")
    local o2 = p1:get()
    check("T2.1 object not nil", o2 ~= nil)
    check("T2.2 created=1", p1:stats().created == 1, p1:stats().created)
    check("T2.3 borrowed=1", p1:stats().borrowed == 1, p1:stats().borrowed)

    emit("=== T3: put returns object to pool ===")
    local ok3, code3 = p1:put(o2)
    check("T3.1 put ok", ok3 == true, error_code.desc(code3 or -1))
    check("T3.2 size=1", p1:stats().size == 1, p1:stats().size)
    check("T3.3 borrowed=0", p1:stats().borrowed == 0, p1:stats().borrowed)

    emit("=== T4: reuse returns the same object ===")
    local o4 = p1:get()
    check("T4.1 same object reused", rawequal(o4, o2))
    check("T4.2 reused=1", p1:stats().reused == 1, p1:stats().reused)
    check("T4.3 created still 1", p1:stats().created == 1, p1:stats().created)
    p1:put(o4)

    emit("=== T5: reset clears state ===")
    local def5 = workload.packet
    local o5 = p1:get()
    def5.use(o5, 42)
    check("T5.1 state written", o5.session == 42, o5.session)
    p1:put(o5)
    check("T5.2 reset cleared session", o5.session == 0, o5.session)
    check("T5.3 reset cleared payload", o5.payload == nil, tostring(o5.payload))

    emit("=== T6: prewarm ===")
    local p6 = mk(workload.packet, { max = 64, prewarm = 10 })
    check("T6.1 size=10", p6:stats().size == 10, p6:stats().size)
    check("T6.2 created=10", p6:stats().created == 10, p6:stats().created)
    check("T6.3 borrowed=0 (预热不入借出计数)", p6:stats().borrowed == 0, p6:stats().borrowed)

    emit("=== T7: pool full — put must not block ===")
    local p7 = mk(workload.packet, { max = 2 })
    local a7, b7, c7 = p7:get(), p7:get(), p7:get()
    p7:put(a7); p7:put(b7)
    check("T7.1 size=2 (full)", p7:stats().size == 2, p7:stats().size)
    local ok7, code7 = p7:put(c7)
    check("T7.2 put rejected when full", ok7 == false)
    check("T7.3 error is ERR_POOL_FULL", code7 == error_code.ERR_POOL_FULL,
        error_code.desc(code7 or -1))
    check("T7.4 discarded=1", p7:stats().discarded == 1, p7:stats().discarded)
    check("T7.5 size stays 2", p7:stats().size == 2, p7:stats().size)

    emit("=== T8: pool full — get still works (never blocks) ===")
    local o8 = p7:get()
    check("T8.1 get returns object", o8 ~= nil)
    check("T8.2 created=3 (fell back to factory)", p7:stats().created == 3, p7:stats().created)

    emit("=== T9: double-free detection ===")
    local p9 = mk(workload.packet, { max = 8 })
    local o9 = p9:get()
    p9:put(o9)
    local ok9, code9 = p9:put(o9)
    check("T9.1 second put rejected", ok9 == false)
    check("T9.2 error is ERR_DOUBLE_FREE", code9 == error_code.ERR_DOUBLE_FREE,
        error_code.desc(code9 or -1))
    check("T9.3 rejected_double=1", p9:stats().rejected_double == 1, p9:stats().rejected_double)
    check("T9.4 size unchanged (no duplicate)", p9:stats().size == 1, p9:stats().size)

    emit("=== T10: foreign object detection ===")
    local p10a = mk(workload.packet, { max = 8 })
    local p10b = mk(workload.packet, { max = 8 })
    local o10 = p10a:get()
    local ok10, code10 = p10b:put(o10)
    check("T10.1 cross-pool put rejected", ok10 == false)
    check("T10.2 error is ERR_FOREIGN_OBJECT", code10 == error_code.ERR_FOREIGN_OBJECT,
        error_code.desc(code10 or -1))
    check("T10.3 rejected_foreign=1", p10b:stats().rejected_foreign == 1,
        p10b:stats().rejected_foreign)

    emit("=== T11: reset failure must not poison the pool ===")
    local p11 = pool.new({
        name = "bad_reset",
        factory = function() return { v = 0 } end,
        reset = function() error("reset boom") end,
        max = 8,
    })
    local o11 = p11:get()
    o11.v = 99
    local ok11, code11 = p11:put(o11)
    check("T11.1 put rejected", ok11 == false)
    check("T11.2 error is ERR_RESET_FAILED", code11 == error_code.ERR_RESET_FAILED,
        error_code.desc(code11 or -1))
    check("T11.3 size=0 (dirty object not stored)", p11:stats().size == 0, p11:stats().size)
    check("T11.4 reset_failed=1", p11:stats().reset_failed == 1, p11:stats().reset_failed)

    emit("=== T12: clear ===")
    local p12 = mk(workload.packet, { max = 32, prewarm = 8 })
    local n12 = p12:clear()
    check("T12.1 cleared 8", n12 == 8, n12)
    check("T12.2 size=0", p12:stats().size == 0, p12:stats().size)

    emit("=== T13: stats field completeness ===")
    local s13 = mk(workload.packet, { max = 4 }):stats()
    local need = { "name", "size", "max", "created", "reused", "borrowed", "peak",
                   "rejected_foreign", "rejected_double", "discarded", "reset_failed" }
    local miss = {}
    for _, k in ipairs(need) do
        if s13[k] == nil then miss[#miss + 1] = k end
    end
    check("T13.1 all fields present", #miss == 0, table.concat(miss, ","))

    emit("=== T14: borrowed / peak ===")
    local p14 = mk(workload.packet, { max = 32 })
    local held = {}
    for i = 1, 5 do held[i] = p14:get() end
    check("T14.1 borrowed=5", p14:stats().borrowed == 5, p14:stats().borrowed)
    for i = 1, 3 do p14:put(held[i]) end
    check("T14.2 borrowed=2", p14:stats().borrowed == 2, p14:stats().borrowed)
    check("T14.3 peak=5", p14:stats().peak == 5, p14:stats().peak)
    for i = 4, 5 do p14:put(held[i]) end

    emit("=== T15: multiple pools are isolated ===")
    local pa = mk(workload.packet, { max = 4, prewarm = 3 })
    local pb = mk(workload.aoi_entity, { max = 4, prewarm = 2 })
    local pc = mk(workload.damage_event, { max = 4, prewarm = 1 })
    check("T15.1 pa size=3", pa:stats().size == 3, pa:stats().size)
    check("T15.2 pb size=2", pb:stats().size == 2, pb:stats().size)
    check("T15.3 pc size=1", pc:stats().size == 1, pc:stats().size)
    local oa, ob = pa:get(), pb:get()
    check("T15.4 packet obj has cmd field", oa.cmd ~= nil)
    check("T15.5 aoi obj has neighbors field", ob.neighbors ~= nil)
    check("T15.6 pa size=2 after get", pa:stats().size == 2, pa:stats().size)
    check("T15.7 pb size=1 after get", pb:stats().size == 1, pb:stats().size)

    emit("=== T16: borrowed-but-never-returned objects are GC-able ===")
    -- owned 是弱 key 表：借出不还的对象不应被池永久持有
    local p16 = mk(workload.packet, { max = 4096 })
    collectgarbage("collect")
    local before16 = collectgarbage("count")
    for _ = 1, 20000 do
        local o = p16:get()      -- 借出后不归还
        o = nil
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local after16 = collectgarbage("count")
    local growth_kb = after16 - before16
    -- 若 owned 是强引用，20000 个对象约 3MB 无法回收；弱表则应接近 0
    check("T16.1 heap growth < 512KB", growth_kb < 512,
        string.format("%.1f KB", growth_kb))
    check("T16.2 leaked borrow count visible", p16:stats().borrowed == 20000,
        p16:stats().borrowed)

    emit("=== T17: reuse_rate ===")
    local p17 = mk(workload.packet, { max = 8, prewarm = 4 })
    for i = 1, 10 do
        local o = p17:get()
        p17:put(o)
    end
    -- 每次 get 后立即 put，池始终非空 → 10 次全部命中复用，created 恒为预热的 4
    local rate17 = p17:reuse_rate()
    check("T17.1 reuse_rate in (0,1)", rate17 > 0 and rate17 < 1,
        string.format("%.3f", rate17))
    check("T17.2 reused=10", p17:stats().reused == 10, p17:stats().reused)
    check("T17.3 created=4 (only prewarm)", p17:stats().created == 4, p17:stats().created)

    emit("=== T18: 10000-iteration stability ===")
    local p18 = mk(workload.damage_event, { max = 64, prewarm = 16 })
    local def18 = workload.damage_event
    local acc18 = 0
    for i = 1, 10000 do
        local o = p18:get()
        acc18 = acc18 + def18.use(o, i)
        p18:put(o)
    end
    local s18 = p18:stats()
    check("T18.1 no error, acc > 0", acc18 > 0, acc18)
    -- 顺序借还时池大小稳定在预热数，不会涨到 max（max 只是上限，不是目标水位）
    check("T18.2 size stable at prewarm(16)", s18.size == 16, s18.size)
    check("T18.3 borrowed back to 0", s18.borrowed == 0, s18.borrowed)
    check("T18.4 no rejected/discarded", s18.rejected_double == 0
        and s18.rejected_foreign == 0 and s18.discarded == 0,
        string.format("d=%d f=%d disc=%d", s18.rejected_double, s18.rejected_foreign, s18.discarded))
    check("T18.5 created <= prewarm+peak", s18.created <= 16 + s18.peak,
        string.format("created=%d peak=%d", s18.created, s18.peak))

    emit(string.format("\n  Subtotal: %d PASS, %d FAIL", pass, fail))

    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_pool", handlers)

return handlers
