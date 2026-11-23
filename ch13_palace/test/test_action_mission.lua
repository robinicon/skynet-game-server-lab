-- test_action_mission.lua — 批次三：任务领奖
--
-- 迁移自 MissionService.claimMissionReward，判定顺序保持一致：
--   任务记录不存在 → 已领取 → 未完成 → 发奖并置 claimed。
-- 奖励发放复用道具语义：货币类道具转货币，其余进背包。

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
    local t = testutil.new("test_action_mission")
    local E, FAIL = schema.errors, -200

    local name = "mission_batch@test"
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    t.eq(code, E.OK, "T0 create account")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)

    -- ===== 无任务记录 =====
    local r = act(agent, 1, "u.missionClaimReward", { 5001 })
    t.eq(r.err, FAIL, "T1 claim without record fails")
    t.eq(r.result.reason, "mission_not_found", "T1 reason mission_not_found")

    -- ===== 未完成 =====
    skynet.call(db, "lua", "set_fields", euid, {
        missions = { [5001] = { progress = 2, completed = false } },
    })
    r = act(agent, 2, "u.missionClaimReward", { 5001 })
    t.eq(r.result.reason, "not_completed", "T2 reason not_completed")
    t.eq(r.delta, nil, "T2 failed claim carries no delta")

    -- ===== 完成 → 领奖（金锭 9001 转金币 1000）=====
    skynet.call(db, "lua", "set_fields", euid, {
        missions = { [5001] = { progress = 3, completed = true } },
    })
    local before = state_of(agent)
    r = act(agent, 3, "u.missionClaimReward", { 5001 })
    t.eq(r.err, E.OK, "T3 claim ok")
    t.eq(r.result.gain, 1000, "T3 reward = 金锭 value 1000 * 1")
    t.eq(r.result.field, "gold", "T3 reward routed to gold")
    local st = state_of(agent)
    t.eq(st[schema.fid("gold")], 1000, "T3 gold credited")
    t.eq(st[schema.fid("missions")][5001].claimed, true, "T3 record marked claimed")
    t.eq(r.delta.rev, before.__rev + 1, "T3 rev advances once")

    -- ===== 重复领取 =====
    r = act(agent, 4, "u.missionClaimReward", { 5001 })
    t.eq(r.result.reason, "already_claimed", "T4 reason already_claimed")

    -- ===== 银币奖励（9002 银锭 value 500 * 2）=====
    skynet.call(db, "lua", "set_fields", euid, {
        missions = { [5001] = { progress = 3, completed = true, claimed = true },
                     [5002] = { progress = 5, completed = true } },
    })
    r = act(agent, 5, "u.missionClaimReward", { 5002 })
    t.eq(r.err, E.OK, "T5 claim silver mission ok")
    t.eq(r.result.gain, 1000, "T5 reward = 500 * 2")
    st = state_of(agent)
    t.eq(st[schema.fid("silver")], 1000, "T5 silver credited")

    -- ===== 道具奖励（5003 → 中还丹 x3）=====
    skynet.call(db, "lua", "set_fields", euid, {
        missions = { [5002] = { progress = 5, completed = true, claimed = true },
                     [5003] = { progress = 1, completed = true } },
    })
    r = act(agent, 6, "u.missionClaimReward", { 5003 })
    t.eq(r.err, E.OK, "T6 claim item mission ok")
    t.eq(r.result.field, "bag", "T6 reward routed to bag")
    st = state_of(agent)
    t.eq(st[schema.fid("bag")][1002], 3, "T6 中还丹 x3 in bag")

    local manifest = skynet.call(agent, "lua", "manifest")
    t.eq(#manifest.by_handler.mission, 1, "T7 mission handler owns 1 action")
    t.check(skynet.call(db, "lua", "flush"), "T7 flush")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
