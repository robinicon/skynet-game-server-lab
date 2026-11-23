-- test_u6.lua — U6 M3 次要玩法单测（rank/gacha/home/errand 降级版）
--
-- 覆盖：本服排行降序+我的名次（复用 hub local.power）、抽卡确定性+10抽保底+扣款、
-- 家园升级+结算旧产出、办差领取+重复防护。
-- 期望值按 U6_M3_DEVLOG §2 规则与 gamedata gacha/home/errand 表推导，不写魔法数。
-- rank 复用全局 hub（main 第 5 参注入），用唯一 rankKey 隔离（handler 内固定 local.power，
-- 通过不同战力值 + 独立实体避免与其他测试串味）。

local skynet   = require "skynet"
local schema   = require "shared.schema"
local message  = require "shared.message"
local testutil = require "shared.testutil"

local M = {}
local PWD = "0123456789abcdef0123456789abcdef"

local function act(agent, id, op, params)
    local env = message.normalize_in({ id = id, op = op, params = params or {} })
    return skynet.call(agent, "lua", "dispatch", env)
end

local function state_of(agent)
    return skynet.call(agent, "lua", "state")
end

local function setf(db, euid, fields)
    skynet.call(db, "lua", "set_fields", euid, fields)
end

local function make_agent(db, login, name, hub)
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)
    if hub then skynet.call(agent, "lua", "set_hub", hub) end
    return agent, euid
end


function M.run(db, login, gate, ws_addr, hub)
    local t = testutil.new("test_u6")
    local E, FAIL = schema.errors, -200
    local F = schema.fields.by_name

    t.check(hub ~= nil, "T0 hub address injected")
    if not hub then return t.result() end

    -- ============ rank：本服排行（两个实体不同战力） ============
    -- 注意：hub 的 local.power 榜是进程内全局，同进程其他测试若也提交过会混入。
    -- 本测试只断言"我的战力在榜上且高分排前"，不强求榜上只有这两个实体。
    local _, uid1 = skynet.call(login, "lua", "create_account", "u6_rank_c@test", PWD)
    local euid1 = skynet.call(db, "lua", "create_entity", "avatar", 0, "u6_rank_c@test", uid1)
    local _, uid2 = skynet.call(login, "lua", "create_account", "u6_rank_d@test", PWD)
    local euid2 = skynet.call(db, "lua", "create_entity", "avatar", 0, "u6_rank_d@test", uid2)
    setf(db, euid1, { zhanli = 140 })
    setf(db, euid2, { zhanli = 90 })
    local ra = skynet.newservice("agent"); skynet.call(ra, "lua", "init", db, euid1)
    skynet.call(ra, "lua", "set_hub", hub)
    local rb = skynet.newservice("agent"); skynet.call(rb, "lua", "init", db, euid2)
    skynet.call(rb, "lua", "set_hub", hub)
    local sa, sb = 0, 0
    local function RA(op) sa = sa + 1; return act(ra, sa, op, {}) end
    local function RB(op) sb = sb + 1; return act(rb, sb, op, {}) end

    local r1 = RA("u.rankList")
    t.eq(r1.err, E.OK, "T1 rankList ok")
    t.eq(r1.result.ok, true, "T1 rank enabled")
    local r2 = RB("u.rankList")
    t.eq(r2.err, E.OK, "T1 rankList b ok")
    -- 两个实体都在 local.power 榜；分数 140 > 90，rank 1 是高分
    local top = nil
    for _, row in ipairs(r1.result.rows) do if row.score == 140 then top = row break end end
    t.check(top ~= nil, "T1 high-power row present")
    if top then t.eq(top.rank, 1, "T1 high power ranks first") end
    t.eq(r1.result.me.score, 140, "T1 my score in result")
    -- 不做显式销毁：skynet 无 kill API，测试进程退出即回收，避免误用不存在的接口

    -- ============ gacha：确定性 + 保底 + 扣款 ============
    local agent, euid = make_agent(db, login, "u6_gacha@test")
    setf(db, euid, { gold = 2000, heroes = {}, activity = {} })
    local seq = 0
    local function A(op, params) seq = seq + 1; return act(agent, seq, op, params or {}) end

    -- 第 1 抽：LCG(1)=1103527590, %100=90 → 2003 区间（权重 9），非稀有，gold -100
    local g1 = A("u.gachaDraw", {})
    t.eq(g1.err, E.OK, "T2 gacha draw ok")
    t.eq(g1.result.draws, 1, "T2 draws=1")
    t.eq(g1.result.tpl, 2003, "T2 deterministic first draw")
    t.eq(g1.result.rare, false, "T2 first draw not rare")
    t.eq(g1.result.gold, 1900, "T2 gold -cost")
    t.eq(g1.result.cost, 100, "T2 cost from meta")
    local st = state_of(agent)
    t.eq(st[F.activity].gacha.draws, 1, "T2 draws persisted")
    t.eq(st[F.gold], 1900, "T2 gold persisted")

    -- 连抽到第 10 抽：前 9 抽 pity 累积到 9，第 10 抽强制稀有 2004
    local last
    for i = 2, 10 do last = A("u.gachaDraw", {}) end
    t.eq(last.err, E.OK, "T3 tenth draw ok")
    t.eq(last.result.draws, 10, "T3 draws=10")
    t.eq(last.result.forced, true, "T3 pity forced rare at 10th")
    t.eq(last.result.tpl, 2004, "T3 forced rare tier")
    t.eq(last.result.rare, true, "T3 rare=true")
    t.eq(last.result.pity, 0, "T3 pity reset after rare")

    -- 金币不足
    setf(db, euid, { gold = 50 })
    local gf = A("u.gachaDraw", {})
    t.eq(gf.err, FAIL, "T4 gacha gold not enough")
    t.eq(gf.result.reason, "gold_not_enough", "T4 reason")

    -- ============ home：升级 + 结算旧产出 ============
    local hagent, heuid = make_agent(db, login, "u6_home@test")
    setf(db, heuid, { gold = 1000, bag = {}, activity = {} })
    local hs = 0
    local function H(op, params) hs = hs + 1; return act(hagent, hs, op, params or {}) end

    local hi = H("u.homeInfo", {})
    t.eq(hi.err, E.OK, "T5 homeInfo ok")
    t.eq(hi.result.level, 1, "T5 initial level 1")
    t.eq(hi.result.upgradeGold, 200, "T5 upgrade to lv2 costs 200")

    local hu = H("u.homeUpgrade", {})
    t.eq(hu.err, E.OK, "T6 homeUpgrade ok")
    t.eq(hu.result.level, 2, "T6 level 2")
    t.eq(hu.result.cost, 200, "T6 cost 200")
    t.eq(hu.result.gold, 800, "T6 gold 800")
    t.eq(hu.result.produced, 1, "T6 old level produces 1 item")
    t.eq(hu.result.producedItem, 1001, "T6 produce item 1001")
    local hst = state_of(hagent)
    t.eq(hst[F.activity].home.level, 2, "T6 level persisted")
    t.eq(hst[F.bag][1001], 1, "T6 produce added to bag")   -- 背包键是数字（baglib 规范化）

    -- ============ errand：领取 + 防重复 ============
    local eagent, eeuid = make_agent(db, login, "u6_errand@test")
    setf(db, eeuid, { gold = 0, bag = {}, activity = {} })
    local es = 0
    local function EA(op, params) es = es + 1; return act(eagent, es, op, params or {}) end

    local el = EA("u.errandList", {})
    t.eq(el.err, E.OK, "T7 errandList ok")
    t.eq(#el.result.rows, 3, "T7 three errands")

    local ec = EA("u.errandClaim", { 1 })
    t.eq(ec.err, E.OK, "T8 errandClaim ok")
    t.eq(ec.result.gold, 50, "T8 gold +50")
    t.eq(ec.result.itemId, 1001, "T8 item 1001")
    t.eq(ec.result.itemNum, 1, "T8 itemNum 1")
    local est = state_of(eagent)
    t.eq(est[F.gold], 50, "T8 gold persisted")
    t.eq(est[F.bag][1001], 1, "T8 bag persisted")
    t.eq(est[F.activity].errand.claimed[1], true, "T8 claimed flag persisted")  -- 数字键

    -- T8b 货币类奖励叠加：id3 = gold 300 固定 + item 9001(gold kind, value=1000)
    -- 回归点：曾经用 ctx.get("gold") 起算覆盖了固定奖励，落到 1000 而不是 1350
    local ec3 = EA("u.errandClaim", { 3 })
    t.eq(ec3.err, E.OK, "T8b claim gold-kind errand ok")
    t.eq(ec3.result.gold, 300, "T8b fixed gold part")
    t.eq(ec3.result.goldGain, 1000, "T8b currency item part")
    local est3 = state_of(eagent)
    t.eq(est3[F.gold], 1350, "T8b both parts stacked")

    local dup = EA("u.errandClaim", { 1 })
    t.eq(dup.err, FAIL, "T9 duplicate claim fails")
    t.eq(dup.result.reason, "already_claimed", "T9 reason")
    local bad = EA("u.errandClaim", { 999 })
    t.eq(bad.err, FAIL, "T9 unknown errand fails")

    t.check(skynet.call(db, "lua", "flush"), "flush")
    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then
        local ok, res = xpcall(M.run, debug.traceback, ...)
        if not ok then
            skynet.error("[test_u6] crash: " .. tostring(res))
            skynet.ret(skynet.pack({ pass = 0, fail = 1 }))
            return
        end
        skynet.ret(skynet.pack(res))
    end
end)

skynet.start(function() end)

return M
