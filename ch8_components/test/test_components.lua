-- test/test_components.lua — 组件生命周期与消息路由测试
--
-- A 组：通过 agent 服务（集成）
-- B 组：直接用 agent_core（可构造异常组件，验证隔离性）

local skynet     = require "skynet"
local core_mod   = require "shared.agent_core"
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

local handlers = {}

function handlers.run()
    pass, fail = 0, 0
    out = {}

    -- ============================================================
    emit("=== A1: agent startup loads base components ===")
    local agent = skynet.newservice("agent")
    local loaded = skynet.call(agent, "lua", "init", 1001, { bag_capacity = 20 })
    check("A1.1 three components loaded", #loaded == 3, table.concat(loaded, ","))
    check("A1.2 load order is bag,skill,quest",
        loaded[1] == "bag" and loaded[2] == "skill" and loaded[3] == "quest",
        table.concat(loaded, ","))

    local events = skynet.call(agent, "lua", "events")
    local init_order = {}
    for _, e in ipairs(events) do
        if e.phase == "init" then init_order[#init_order + 1] = e.name end
    end
    check("A1.3 init() called in load order",
        table.concat(init_order, ",") == "bag,skill,quest", table.concat(init_order, ","))

    emit("=== A2: message routing ===")
    local c1, n1 = skynet.call(agent, "lua", "client", "bag.add", 101, 5)
    check("A2.1 bag.add routed", c1 == error_code.OK, c1)
    check("A2.2 returns multi values", n1 == 5, n1)
    local c2, info = skynet.call(agent, "lua", "client", "bag.list")
    check("A2.3 bag.list returns data", c2 == error_code.OK and info.kinds == 1,
        info and info.kinds)

    emit("=== A3: cross-component messaging (quest → bag) ===")
    -- 接任务 → 推进 10 点 → 完成 → 自动发奖到背包（走 core 路由，不直接依赖）
    skynet.call(agent, "lua", "client", "quest.accept", 5001)
    local c3 = skynet.call(agent, "lua", "client", "quest.progress", 5001, 10)
    check("A3.1 quest completed", c3 == error_code.OK, c3)
    local c4, info4 = skynet.call(agent, "lua", "client", "bag.list")
    check("A3.2 reward delivered to bag", c4 == error_code.OK and info4.items[2001] == 5,
        info4 and info4.items and info4.items[2001])

    emit("=== A4: cross-component messaging (skill → bag) ===")
    -- 学技能需要消耗技能书（item 1001），先加一本
    skynet.call(agent, "lua", "client", "bag.add", 1001, 1)
    local c5 = skynet.call(agent, "lua", "client", "skill.learn", 201)
    check("A4.1 skill learned", c5 == error_code.OK, c5)
    local c6, info6 = skynet.call(agent, "lua", "client", "bag.list")
    check("A4.2 skill book consumed", info6.items[1001] == nil, info6.items[1001])

    emit("=== A5: dynamic component injection (no restart) ===")
    local has_before = skynet.call(agent, "lua", "has", "vip")
    check("A5.1 vip not loaded initially", has_before == false)
    local ok7, err7 = skynet.call(agent, "lua", "load", "vip")
    check("A5.2 vip injected at runtime", ok7 == true, tostring(err7))
    local c8, lv = skynet.call(agent, "lua", "client", "vip.set", 3)
    check("A5.3 vip handler works immediately", c8 == error_code.OK and lv == 3, lv)
    check("A5.4 vip appended to order",
        table.concat(skynet.call(agent, "lua", "list"), ",") == "bag,skill,quest,vip",
        table.concat(skynet.call(agent, "lua", "list"), ","))

    emit("=== A6: unknown command is rejected ===")
    local c9, msg9 = skynet.call(agent, "lua", "client", "nonexistent.cmd")
    check("A6.1 unknown cmd returns error", c9 == error_code.ERR_INVALID_ARG, c9)
    check("A6.2 error message present", type(msg9) == "string", msg9)

    emit("=== A7: exit shuts down in REVERSE order ===")
    local ok10, errs10 = skynet.call(agent, "lua", "exit")
    check("A7.1 shutdown all ok", ok10 == true, table.concat(errs10 or {}, ";"))
    local ev10 = skynet.call(agent, "lua", "events")
    local down_order = {}
    for _, e in ipairs(ev10) do
        if e.phase == "shutdown" then down_order[#down_order + 1] = e.name end
    end
    check("A7.2 shutdown is reverse of load",
        table.concat(down_order, ",") == "vip,quest,skill,bag",
        table.concat(down_order, ","))

    -- ============================================================
    -- B 组：直接用 agent_core，可构造异常场景
    emit("=== B1: component isolation — init failure must not break others ===")
    local ctx = {}
    local core = core_mod.new({ ctx = ctx })
    core:load("bag", require "shared.component_bag")
    local ok_b, err_b = core:load("broken", {
        init = function() error("init boom") end,
        handlers = { ["broken.x"] = function() return error_code.OK end },
    })
    check("B1.1 broken component rejected", ok_b == false, tostring(err_b))
    check("B1.2 healthy component still works",
        core:dispatch("bag.add", 1, 1) == error_code.OK)
    check("B1.3 broken handler not registered",
        core:dispatch("broken.x") == error_code.ERR_INVALID_ARG)

    emit("=== B2: duplicate load rejected ===")
    local ok_d, err_d = core:load("bag", require "shared.component_bag")
    check("B2.1 duplicate rejected", ok_d == false, tostring(err_d))

    emit("=== B3: unload removes handlers ===")
    local ok_u = core:unload("bag")
    check("B3.1 unload ok", ok_u == true)
    check("B3.2 handler removed", core:dispatch("bag.add", 1, 1) == error_code.ERR_INVALID_ARG)
    check("B3.3 not in list", #core:list() == 0, table.concat(core:list(), ","))

    emit("=== B4: shutdown error isolation ===")
    local ctx2 = {}
    local core2 = core_mod.new({ ctx = ctx2 })
    core2:load("bag", require "shared.component_bag")
    core2:load("bad_shutdown", {
        init = function() return true end,
        shutdown = function() error("shutdown boom") end,
    })
    core2:load("quest", require "shared.component_quest")
    local ok_s, errs_s = core2:shutdown()
    -- 抛错的组件被隔离，其余组件仍应完成 shutdown
    check("B4.1 shutdown reports errors", ok_s == false, "expected false")
    check("B4.2 other components still shut down",
        ctx2.bag == nil and ctx2.quest == nil,
        string.format("bag=%s quest=%s", tostring(ctx2.bag), tostring(ctx2.quest)))

    emit("=== B5: message counting + split threshold ===")
    local ctx3 = {}
    local core3 = core_mod.new({ ctx = ctx3 })
    core3:load("skill", require "shared.component_skill")
    for i = 1, 5 do
        core3:dispatch("skill.learn", i)        -- 会失败（无 bag），但仍计数
    end
    local st3 = core3:stats(3)
    check("B5.1 messages counted", st3.components[1].messages == 5, st3.components[1].messages)
    check("B5.2 should_split when over threshold",
        st3.components[1].should_split == true, st3.components[1].messages)
    local st3b = core3:stats(1000)
    check("B5.3 no split below threshold", st3b.components[1].should_split == false)

    emit(string.format("\n  Subtotal: %d PASS, %d FAIL", pass, fail))
    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_components", handlers)

return handlers
