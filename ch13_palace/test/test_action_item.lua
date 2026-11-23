-- test_action_item.lua — 批次二：背包/道具（使用 / 出售）
--
-- 迁移自 ItemService.useProp / itemSale。规则：
--   gold/silver 类道具使用后按 value*count 转货币
--   elixir 只能由英雄升级吞掉，直接使用返回 not_usable
--   material 无使用效果；sellPrice=0 不可出售

local skynet   = require "skynet"
local schema   = require "shared.schema"
local message  = require "shared.message"
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
    local t = testutil.new("test_action_item")
    local E, FAIL = schema.errors, -200

    local name = "item_batch@test"
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    t.eq(code, E.OK, "T0 create account")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)

    -- ===== 使用货币类道具 =====
    t.eq(act(agent, 1, "u.dev.itemAdd", { 9001, 2 }).err, E.OK, "T1 give 2 金锭")
    local r = act(agent, 2, "u.useItem", { 9001, 2, 0 })
    t.eq(r.err, E.OK, "T1 use gold pack ok")
    t.eq(r.result.gain, 2000, "T1 gain = 1000 * 2")
    local st = state_of(agent)
    t.eq(st[schema.fid("gold")], 2000, "T1 gold credited")
    t.eq(st[schema.fid("bag")][9001], nil, "T1 pack consumed")

    r = act(agent, 3, "u.useItem", { 9001, 1, 0 })
    t.eq(r.err, FAIL, "T2 use without stock fails")
    t.eq(r.result.reason, "item_not_enough", "T2 reason item_not_enough")

    -- ===== 经验丹不可直接使用 =====
    t.eq(act(agent, 4, "u.dev.itemAdd", { 1001, 3 }).err, E.OK, "T3 give 3 小还丹")
    r = act(agent, 5, "u.useItem", { 1001, 1, 0 })
    t.eq(r.err, FAIL, "T3 elixir not usable directly")
    t.eq(r.result.reason, "not_usable", "T3 reason not_usable")

    -- ===== 出售：单价来自配置 =====
    local before = state_of(agent)
    r = act(agent, 6, "u.itemSale", { 1001, 3 })
    t.eq(r.err, E.OK, "T4 sale elixir ok")
    t.eq(r.result.gain, 30, "T4 gain = sellPrice 10 * 3")
    st = state_of(agent)
    t.eq(st[schema.fid("silver")], 30, "T4 silver credited")
    t.eq(st[schema.fid("bag")][1001], nil, "T4 sold all elixirs")
    t.eq(r.delta.rev, before.__rev + 1, "T4 rev advances once")

    r = act(agent, 7, "u.itemSale", { 1001, 1 })
    t.eq(r.result.reason, "item_not_enough", "T5 sell more than owned fails")

    -- ===== 不可出售类：先判库存，再判可售 =====
    r = act(agent, 8, "u.itemSale", { 3001, 1 })
    t.eq(r.result.reason, "item_not_enough", "T6 unknown stock checked first")
    t.eq(act(agent, 9, "u.dev.itemAdd", { 3001, 2 }).err, E.OK, "T6 give 2 官印")
    r = act(agent, 10, "u.itemSale", { 3001, 1 })
    t.eq(r.err, FAIL, "T6 material not sellable")
    t.eq(r.result.reason, "not_sellable", "T6 reason not_sellable")

    -- ===== 参数校验与未知道具 =====
    r = act(agent, 11, "u.useItem", { 999999, 1, 0 })
    t.eq(r.result.reason, "item_not_found", "T7 unknown item template")
    r = act(agent, 12, "u.useItem", { 9001, 0, 0 })
    t.eq(r.result.reason, "bad_count", "T7 zero count rejected")
    r = act(agent, 13, "u.useItem", { "abc", 1, 0 })
    t.eq(r.result.reason, "bad_item_id", "T7 non numeric item id rejected")

    local manifest = skynet.call(agent, "lua", "manifest")
    t.eq(#manifest.by_handler.item, 2, "T8 item handler owns 2 actions")
    t.check(skynet.call(db, "lua", "flush"), "T8 flush")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
