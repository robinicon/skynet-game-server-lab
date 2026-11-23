-- test_action_hero.lua — 批次一：将星养成（升级 / 加官 / 进爵）
--
-- 断言的是从原工程迁移过来的规则本身，不是脚手架：
--   升级受 角色等级 / 英雄上限 / 加官等级上限 三重约束
--   经验丹按 小→中→大 贪心吞，溢出经验留在英雄身上
--   加官要求当前档 lvLimit 达标，进爵要求 advance >= breakLvLimit
-- 期望值全部可用 conf/gamedata.xlsx 手算复核（见 docs/samples/hero.json 的 derivation 字段）。

local skynet   = require "skynet"
local schema   = require "shared.schema"
local message  = require "shared.message"
local gamedata = require "shared.gamedata"
local testutil = require "shared.testutil"

local M = {}
local PWD = "0123456789abcdef0123456789abcdef"

local function act(agent, id, op, params)
    local env = message.normalize_in({ id = id, op = op, params = params })
    return skynet.call(agent, "lua", "dispatch", env)
end

local function state_of(agent)
    return skynet.call(agent, "lua", "state")
end

function M.run(db, login)
    local t = testutil.new("test_action_hero")
    local E, FAIL = schema.errors, -200

    local name = "hero_batch@test"
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    t.eq(code, E.OK, "T0 create account")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    t.eq(euid, uid, "T0 entity uid")

    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)

    -- 角色等级抬到 30，让英雄升级只受加官上限约束
    t.eq(skynet.call(db, "lua", "set_fields", euid, { level = 30 }), true, "T0 avatar level seeded")

    -- ===== 升级：前置校验 =====
    local r = act(agent, 1, "u.heroUpdateLvAuto", { "nope", false })
    t.eq(r.err, FAIL, "T1 missing hero -> business error")
    t.eq(r.result.reason, "hero_not_found", "T1 reason hero_not_found")

    t.eq(act(agent, 2, "u.dev.heroLv", { "h1", 1, 2001 }).err, E.OK, "T1 seed hero h1 lv1")

    r = act(agent, 3, "u.heroUpdateLvAuto", { "h1", false })
    t.eq(r.err, FAIL, "T2 no elixir -> fail")
    t.eq(r.result.reason, "elixir_not_enough", "T2 reason elixir_not_enough")
    t.eq(r.delta, nil, "T2 failed action carries no delta")

    -- ===== 升级：单步，消耗 1 颗小还丹 =====
    t.eq(act(agent, 4, "u.dev.itemAdd", { 1001, 10 }).err, E.OK, "T3 give 10 small elixirs")
    local before = state_of(agent)
    r = act(agent, 5, "u.heroUpdateLvAuto", { "h1", false })
    t.eq(r.err, E.OK, "T3 level up ok")
    t.eq(r.result.lv, 2, "T3 lv 1 -> 2")
    t.eq(r.result.exp, 0, "T3 exp fully consumed")
    t.eq(r.result.cost["1001"], 1, "T3 cost 1 small elixir (need 100 / value 100)")
    t.eq(r.result.gainedExp, 100, "T3 gained 100 exp")
    t.eq(r.delta.rev, before.__rev + 1, "T3 rev advances by exactly one")
    local after = state_of(agent)
    t.eq(after[schema.fid("heroes")].h1.lv, 2, "T3 persisted hero lv")
    t.eq(after[schema.fid("bag")][1001], 9, "T3 elixir consumed from bag")

    -- ===== 升级：auto 撞到加官上限（advance 0 -> lvLimit 10）=====
    t.eq(act(agent, 6, "u.dev.itemAdd", { 1003, 2 }).err, E.OK, "T4 give 2 big elixirs")
    r = act(agent, 7, "u.heroUpdateLvAuto", { "h1", true })
    t.eq(r.err, E.OK, "T4 auto level up ok")
    t.eq(r.result.toLv, 10, "T4 auto target capped by lvLimit 10")
    t.eq(r.result.lv, 10, "T4 hero at cap level")
    t.eq(r.result.exp, 300, "T4 overflow exp kept on hero (2900 gained - 2600 spent)")
    t.eq(r.result.cost["1001"], 9, "T4 small elixirs drained first")
    t.eq(r.result.cost["1003"], 1, "T4 then one big elixir")
    t.eq(gamedata.hero_need_exp(2, 10), 2600, "T4 exp curve matches config (150..500)")

    -- 已到加官上限，再升必须失败
    r = act(agent, 8, "u.heroUpdateLvAuto", { "h1", true })
    t.eq(r.result.reason, "advance_level_limit", "T4 capped at lvLimit until advance")

    -- ===== 加官（u.heroUpdateAdvanceLv）=====
    r = act(agent, 9, "u.heroUpdateAdvanceLv", { "h1" })
    t.eq(r.err, FAIL, "T5 advance without 官印 fails")
    t.eq(r.result.reason, "item_not_enough", "T5 reason item_not_enough")

    t.eq(act(agent, 10, "u.dev.itemAdd", { 3001, 5 }).err, E.OK, "T5 give 5 官印")
    r = act(agent, 11, "u.heroUpdateAdvanceLv", { "h1" })
    t.eq(r.err, E.OK, "T5 advance ok")
    t.eq(r.result.advance, 1, "T5 advance 0 -> 1")
    t.eq(r.result.nextLvLimit, 20, "T5 next lvLimit is 20")
    after = state_of(agent)
    t.eq(after[schema.fid("heroes")].h1.advance, 1, "T5 persisted advance")
    t.eq(after[schema.fid("bag")][3001], nil, "T5 官印 fully consumed")

    -- 加官后等级上限提到 20，但当前 lv 10 不足以再加官
    r = act(agent, 12, "u.heroUpdateAdvanceLv", { "h1" })
    t.eq(r.result.reason, "level_not_enough", "T5 advance blocked until lv 20")

    -- ===== 进爵（u.heroUpdateLimitLv）=====
    t.eq(act(agent, 13, "u.dev.heroLv", { "h1", 20, 2001, 1, 0 }).err, E.OK, "T6 seed lv20 advance1")
    r = act(agent, 14, "u.heroUpdateLimitLv", { "h1" })
    t.eq(r.err, FAIL, "T6 limit blocked by advance requirement")
    t.eq(r.result.reason, "advance_not_enough", "T6 reason advance_not_enough")

    t.eq(act(agent, 15, "u.dev.heroLv", { "h1", 20, 2001, 2, 0 }).err, E.OK, "T7 seed advance2")
    t.eq(act(agent, 16, "u.dev.itemAdd", { 3002, 2 }).err, E.OK, "T7 give 2 爵位令")
    r = act(agent, 17, "u.heroUpdateLimitLv", { "h1" })
    t.eq(r.err, E.OK, "T7 limit ok")
    t.eq(r.result.limit, 1, "T7 limit 0 -> 1")
    after = state_of(agent)
    t.eq(after[schema.fid("heroes")].h1.limit, 1, "T7 persisted limit")
    t.eq(after[schema.fid("bag")][3002], nil, "T7 爵位令 consumed")

    -- 顶档：配置只有 0..3，limit=3 时不能再升
    t.eq(act(agent, 18, "u.dev.heroLv", { "h1", 20, 2001, 5, 3 }).err, E.OK, "T8 seed limit3")
    r = act(agent, 19, "u.heroUpdateLimitLv", { "h1" })
    t.eq(r.err, FAIL, "T8 limit at config max fails")
    t.eq(r.result.reason, "limit_max", "T8 reason limit_max")

    -- ===== 未知 aid 仍走统一错误码 =====
    local unknown = skynet.call(agent, "lua", "dispatch",
        { kind = message.KIND.ACTION_REQ, seq = 20, aid = 999, params = {} })
    t.eq(unknown.err, E.UNKNOWN_OP, "T9 unknown aid -> -100")

    -- ===== 迁移清单 =====
    local manifest = skynet.call(agent, "lua", "manifest")
    local hero_ops = manifest.by_handler.hero or {}
    t.eq(#hero_ops, 3, "T10 hero handler owns 3 actions")
    t.eq(hero_ops[1], "u.heroUpdateAdvanceLv", "T10 manifest sorted ops")
    t.check(skynet.call(db, "lua", "flush"), "T10 flush")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
