-- test_u4.lua — U4 战斗与关卡批次单测
--
-- 覆盖：关卡 10 连打（逐关推进 + 掉落/经验累计与规则一致）、跳关/等级门槛、
-- 扫荡、战斗确定性种子与胜负结算、商店买卖/限购/货币不足、签到与在线奖励防重。
-- 期望值全部按 U4_DEVLOG §3 的规则与 gamedata.xlsx 数值推导，不写魔法数。

local skynet   = require "skynet"
local schema   = require "shared.schema"
local testutil = require "shared.testutil"

local M = {}
local PWD = "0123456789abcdef0123456789abcdef"

local function act(agent, id, op, params)
    local message = require "shared.message"
    local env = message.normalize_in({ id = id, op = op, params = params or {} })
    return skynet.call(agent, "lua", "dispatch", env)
end

local function state_of(agent)
    return skynet.call(agent, "lua", "state")
end

local function setf(db, euid, fields)
    skynet.call(db, "lua", "set_fields", euid, fields)
end

function M.run(db, login)
    local t = testutil.new("test_u4")
    local E, FAIL = schema.errors, -200
    local F = schema.fields.by_name

    local name = "u4_batch@test"
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    t.eq(code, E.OK, "T0 create account")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)
    local seq = 0
    local function A(op, params) seq = seq + 1; return act(agent, seq, op, params) end

    -- ============ stageInfo 初始 ============
    local r = A("u.stageInfo", {})
    t.eq(r.err, E.OK, "T1 stageInfo ok")
    t.eq(r.result.clearMax, 0, "T1 clearMax=0")
    t.eq(r.result.next.stageId, 1, "T1 next stage 1")

    -- ============ 跳关 / 等级门槛 ============
    r = A("u.stageChallenge", { 3 })
    t.eq(r.result.reason, "stage_locked", "T2 skip stage locked")
    setf(db, euid, { level = 10 })
    r = A("u.stageChallenge", { 1 })
    t.eq(r.err, E.OK, "T3 stage1 challenge ok")
    t.eq(r.result.win, true, "T3 win")

    -- 重置进度，做完整 10 连打（单独账号状态）
    setf(db, euid, { level = 10, gold = 0, silver = 0, bag = {},
                     activity = { stage = { clearMax = 0, exp = 0 } } })
    local sum_exp, sum_gold = 0, 0
    for sid = 1, 10 do
        r = A("u.stageChallenge", { sid })
        t.eq(r.err, E.OK, "T4 stage" .. sid .. " challenge ok")
        t.eq(r.result.clearMax, sid, "T4 clearMax=" .. sid)
        sum_exp = sum_exp + r.result.exp
        sum_gold = sum_gold + r.result.gold
    end
    t.eq(sum_exp, 1900, "T4 10-stage total exp = 1900")
    t.eq(sum_gold, 950, "T4 10-stage total gold = 950")

    local st = state_of(agent)
    t.eq(st[schema.fid("activity")].stage.clearMax, 10, "T4 persisted clearMax=10")
    t.eq(st[schema.fid("activity")].stage.exp, 1900, "T4 persisted exp=1900")
    t.eq(st[schema.fid("gold")], 950, "T4 persisted gold=950")
    -- 掉落：关1-5 dropItem=1001 (1,1,1,2,2)=7；关6-10 dropItem=1002 (2,3,3,3,4)=15
    local bag = st[schema.fid("bag")]
    t.eq(bag[1001], 7, "T4 drop 1001 x7")
    t.eq(bag[1002], 15, "T4 drop 1002 x15")

    r = A("u.stageChallenge", { 11 })
    t.eq(r.result.reason, "stage_not_found", "T5 stage 11 not found")

    -- ============ 扫荡 ============
    local gold_before = state_of(agent)[schema.fid("gold")]
    r = A("u.stageSweep", { 1, 3 })
    t.eq(r.err, E.OK, "T6 sweep stage1 ok")
    t.eq(r.result.times, 3, "T6 sweep times=3")
    t.eq(r.result.exp, 300, "T6 sweep exp = 100*3")
    t.eq(state_of(agent)[schema.fid("gold")], gold_before + 150, "T6 gold +150")
    -- 重置 clearMax=2 后扫荡 stage5 属未通关（10 连打后 clearMax=10，stage5 已通关）
    setf(db, euid, { activity = { stage = { clearMax = 2, exp = 1900 } } })
    r = A("u.stageSweep", { 5, 1 })
    t.eq(r.result.reason, "stage_not_cleared", "T7 sweep uncleared stage fails")

    -- ============ fight：确定性 + 胜负 ============
    setf(db, euid, {
        heroes = { h1 = { tpl = 2003, lv = 20, advance = 0, limit = 0 } },
        activity = { stage = { clearMax = 0, exp = 0 } },
    })
    -- 2003 quality=4, lv=20 → power = 40+100 = 140
    local fs = A("u.fightStart", { 1 })
    t.eq(fs.result.power, 140, "T8 power = 140")
    t.eq(fs.result.seed, 1000 + 140, "T8 seed deterministic")
    t.eq(fs.result.canWin, true, "T8 canWin")
    local settle = A("u.fightSettle", { 1 })
    t.eq(settle.result.win, true, "T9 fightSettle win")
    t.eq(settle.result.gold, 50, "T9 settle gold = stage1")
    local st9 = state_of(agent)
    t.eq(st9[schema.fid("activity")].stage.clearMax, 1, "T9 settle advances clearMax")
    t.eq(st9[schema.fid("activity")].fight.last.win, true, "T9 battle report written")

    setf(db, euid, { heroes = {}, activity = { stage = { clearMax = 0, exp = 0 } } })
    local lose = A("u.fightSettle", { 3 })
    t.eq(lose.result.win, false, "T10 no heroes lose")
    t.eq(lose.result.power, 0, "T10 power=0")
    t.eq(lose.result.gold, nil, "T10 defeat no gold reward")
    t.eq(state_of(agent)[schema.fid("activity")].fight.last.win, false, "T10 defeat report written")

    -- ============ shop ============
    setf(db, euid, { gold = 1000, silver = 500, bag = {},
                     activity = { shop = { bought = {} } } })
    local sl = A("u.shopList", {})
    t.eq(sl.result.goods[1].goodsId, 101, "T11 shopList sorted")
    t.eq(#sl.result.goods, 3, "T11 shopList 3 goods")
    local buy = A("u.shopBuy", { 101, 2 })
    t.eq(buy.err, E.OK, "T12 buy ok")
    t.eq(buy.result.spent, 200, "T12 spent = 100*2")
    t.eq(state_of(agent)[schema.fid("gold")], 800, "T12 gold deducted")
    t.eq(state_of(agent)[schema.fid("bag")][1001], 2, "T12 item gained")
    local lim = A("u.shopBuy", { 102, 6 })
    t.eq(lim.result.reason, "limit_exceeded", "T13 buy beyond limit fails")
    local poor = A("u.shopBuy", { 103, 3 })
    t.eq(poor.result.reason, "silver_not_enough", "T14 silver not enough")

    -- ============ reward 签到 ============
    setf(db, euid, { gold = 0, bag = {}, activity = { reward = { signDay = 0 } } })
    local sg1 = A("u.rewardSign", { 1 })
    t.eq(sg1.err, E.OK, "T15 sign day1 ok")
    t.eq(sg1.result.gain, 1000, "T15 day1 = 金锭 value1000")
    t.eq(state_of(agent)[schema.fid("gold")], 1000, "T15 gold credited")
    local sgdup = A("u.rewardSign", { 1 })
    t.eq(sgdup.result.reason, "already_signed", "T16 duplicate sign fails")
    local sgmismatch = A("u.rewardSign", { 4 })
    t.eq(sgmismatch.result.reason, "sign_day_mismatch", "T17 skip day fails")
    local sg2 = A("u.rewardSign", { 2 })
    t.eq(sg2.err, E.OK, "T18 sign day2 ok")

    -- ============ reward 在线 ============
    setf(db, euid, { gold = 0, bag = {}, activity = { reward = { onlineMin = 60, onlineClaimed = {} } } })
    local ol = A("u.rewardOnline", { 30 })
    t.eq(ol.err, E.OK, "T19 online 30min claim ok")
    local oldup = A("u.rewardOnline", { 30 })
    t.eq(oldup.result.reason, "already_claimed", "T20 online duplicate claim fails")
    local ollack = A("u.rewardOnline", { 120 })
    t.eq(ollack.result.reason, "online_time_not_enough", "T21 online 120min not reached")

    -- ============ handler 归属 ============
    local manifest = skynet.call(agent, "lua", "manifest")
    t.eq(#manifest.by_handler.stage, 3, "T22 stage handler owns 3 actions")
    t.eq(#manifest.by_handler.fight, 2, "T22 fight handler owns 2 actions")
    t.eq(#manifest.by_handler.shop, 2, "T22 shop handler owns 2 actions")
    t.eq(#manifest.by_handler.reward, 2, "T22 reward handler owns 2 actions")
    t.check(skynet.call(db, "lua", "flush"), "T22 flush")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
