-- test/test_ecs.lua — ECS 行为测试
--
-- 覆盖：Lua 低频 ECS / C 高频 ECS / 混合场景 / userdata GC

local skynet  = require "skynet"
local ecs_low = require "shared.ecs_low"
local ecs_c   = require "ecs_high"
local utils   = require "shared.utils"

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

local handlers = {}

function handlers.run()
    pass, fail = 0, 0
    out = {}

    -- ============================================================
    emit("=== L1-L6: Lua ECS lifecycle ===")
    local w = ecs_low.new()
    local e1 = w:create()
    local e2 = w:create()
    check("L1 entity ids increment", e1 == 1 and e2 == 2, string.format("%d,%d", e1, e2))
    check("L2 count=2", w:count() == 2, w:count())

    w:add(e1, "position", { x = 10, y = 20 })
    local p = w:get(e1, "position")
    check("L3 add/get component", p ~= nil and p.x == 10 and p.y == 20,
        p and string.format("%s,%s", tostring(p.x), tostring(p.y)))
    check("L4 has()", w:has(e1, "position") == true)
    check("L5 has() false for missing", w:has(e1, "velocity") == false)

    w:remove(e1, "position")
    check("L6 remove component", w:get(e1, "position") == nil)

    w:destroy(e2)
    check("L7 destroy → count=1", w:count() == 1, w:count())
    check("L8 destroyed entity gone", w:exists(e2) == false)

    -- ============================================================
    emit("=== L9-L11: Lua ECS each / tick ===")
    local w2 = ecs_low.new()
    for i = 1, 5 do
        local e = w2:create()
        w2:add(e, "position", { x = i * 10, y = 0 })
        w2:add(e, "velocity", { x = 1, y = 0 })
        w2:add(e, "health", { hp = 50, maxhp = 100 })
    end
    -- 第 6 个实体只有 position，不应被 each({"position","velocity"}) 命中
    local e6 = w2:create()
    w2:add(e6, "position", { x = 0, y = 0 })

    local seen = 0
    w2:each({ "position", "velocity" }, function(_, pos, vel)
        seen = seen + 1
    end)
    check("L9 each filters by component set", seen == 5, seen)

    -- e1 有 position + velocity → 应该移动
    -- 注意：get() 返回的是 component table 的引用，必须先快照数值再 tick，
    -- 否则 before/after 指向同一个 table，断言永远成立（引用语义陷阱）
    local before_x = w2:get(1, "position").x
    w2:tick(1.0, 1000)
    local after_x = w2:get(1, "position").x
    check("L10 tick moves position", math.abs(after_x - before_x - 1.0) < 1e-6,
        string.format("%s → %s", tostring(before_x), tostring(after_x)))
    -- e6 只有 position → 应被跳过（验证组件过滤，不只是遍历全部）
    local p6 = w2:get(e6, "position")
    check("L10b entity without velocity not moved", p6.x == 0, p6.x)

    local hp = w2:get(1, "health")
    check("L11 tick regenerates hp", hp.hp == 51, hp.hp)

    w2:damage_all(20)
    check("L12 damage_all", w2:get(1, "health").hp == 31, w2:get(1, "health").hp)

    emit("=== L13: Lua ECS bag (low-frequency CRUD) ===")
    local w3 = ecs_low.new()
    for i = 1, 4 do
        local e = w3:create()
        w3:add(e, "bag", { items = { 1, 2, 3 } })
    end
    local total, cnt = w3:bag_total()
    check("L13 bag_total", total == 12 and cnt == 4,
        string.format("total=%d cnt=%d", total, cnt))

    -- ============================================================
    emit("=== C1-C8: C ECS basic ops ===")
    local cw = ecs_c.new(64)
    check("C1 new → count=0", cw:count() == 0, cw:count())
    check("C2 capacity", cw:capacity() >= 64, cw:capacity())

    local ok_add = cw:add(1, 10, 20, 1, 0, 100)
    check("C3 add returns slot", type(ok_add) == "number" and ok_add == 0, tostring(ok_add))
    check("C4 count=1", cw:count() == 1, cw:count())
    check("C5 has()", cw:has(1) == true)

    local px, py, hp2, slot = cw:get(1)
    check("C6 get returns fields", px == 10 and py == 20 and hp2 == 100 and slot == 0,
        string.format("px=%s py=%s hp=%s slot=%s", tostring(px), tostring(py),
            tostring(hp2), tostring(slot)))

    local dup_ok, dup_err = cw:add(1, 0, 0, 0, 0, 100)
    check("C7 duplicate add rejected", dup_ok == false, tostring(dup_err))
    check("C8 count unchanged after dup", cw:count() == 1, cw:count())

    -- ============================================================
    emit("=== C9-C13: C ECS systems ===")
    cw:update(1.0, 1000)
    local nx = cw:get(1)
    check("C9 update moves entity", math.abs(nx - 11.0) < 1e-6, nx)

    local cw2 = ecs_c.new(64)
    cw2:add(1, 999, 500, 100, 0, 100)     -- 会撞右边界
    cw2:update(1.0, 1000)
    local bx, _, _ = cw2:get(1)
    check("C10 bounce at bound", bx <= 1000.0 and bx > 900.0, bx)
    cw2:set_velocity(1, -100, 0)
    cw2:update(1.0, 1000)
    local bx2 = cw2:get(1)
    check("C11 velocity reversed after bounce", bx2 < bx, string.format("%s → %s", bx, bx2))

    local cw3 = ecs_c.new(64)
    cw3:add(1, 0, 0, 0, 0, 100)
    cw3:add(2, 0, 0, 0, 0, 100)
    cw3:damage_all(30)
    check("C12 damage_all", cw3:get(1) ~= nil and select(3, cw3:get(1)) == 70,
        select(3, cw3:get(1)))

    -- swap-remove 关键测试：删中间元素后，其余实体数据必须仍然正确
    local cw4 = ecs_c.new(64)
    for i = 1, 5 do
        cw4:add(i, i * 100, i * 10, 0, 0, 100)
    end
    cw4:del(3)
    check("C13 count after del", cw4:count() == 4, cw4:count())
    check("C14 deleted gone", cw4:has(3) == false)
    local ok_all = true
    for i = 1, 5 do
        if i ~= 3 then
            local x = cw4:get(i)
            if math.abs(x - i * 100) > 1e-6 then ok_all = false end
        end
    end
    check("C15 swap-remove keeps others intact", ok_all)
    check("C16 del non-existent returns false", cw4:del(999) == false)

    -- 扩容
    local cw5 = ecs_c.new(8)
    local grow_ok = true
    for i = 1, 200 do
        if cw5:add(i, i, i, 0, 0, 100) == false then grow_ok = false end
    end
    check("C17 auto-grow beyond initial cap", grow_ok and cw5:count() == 200, cw5:count())
    check("C18 capacity grew", cw5:capacity() >= 200, cw5:capacity())

    -- ============================================================
    emit("=== M1: mixed scenario (C combat tick + Lua bag query) ===")
    local cw6 = ecs_c.new(1024)
    local lw6 = ecs_low.new()
    for i = 1, 100 do
        cw6:add(i, i, i, 1, 1, 100)
        local e = lw6:create()
        lw6:add(e, "bag", { items = { i, i + 1 } })
    end
    for _ = 1, 10 do cw6:update(0.016, 1000) end
    local total6, cnt6 = lw6:bag_total()
    check("M1 C tick ran", cw6:count() == 100, cw6:count())
    check("M2 Lua bag query independent", total6 == 200 and cnt6 == 100,
        string.format("total=%d cnt=%d", total6, cnt6))

    -- ============================================================
    emit("=== G1: userdata GC releases C memory ===")
    collectgarbage("collect"); collectgarbage("collect")
    local before_kb = collectgarbage("count")
    for _ = 1, 100 do
        local tmp = ecs_c.new(1024)   -- 约 32KB C 内存
        tmp:add(1, 0, 0, 0, 0, 100)
        tmp = nil
    end
    collectgarbage("collect"); collectgarbage("collect")
    local after_kb = collectgarbage("count")
    -- Lua heap 本身不含 C 的 malloc 内存，但 userdata 被回收是前提；
    -- 这里断言 Lua 侧堆不增长（C 侧释放由 __gc 保证）
    check("G1 lua heap stable after 100 worlds", after_kb - before_kb < 512,
        string.format("%.1f KB", after_kb - before_kb))

    emit(string.format("\n  Subtotal: %d PASS, %d FAIL", pass, fail))
    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_ecs", handlers)

return handlers
