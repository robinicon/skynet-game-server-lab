-- test_cross.lua — P0.5 跨服 hub 最小链路（4 条核心断言 + 端到端动作）
--
-- 四条断言严格对应 docs/CROSS_SERVER.md §4.3：
--   T1 两个 zone（sid=1/2）各提交 1 条 → rank() 2 行按分数降序
--   T2 同一 (sid, seq) 重复提交 → 分数与 rev 不变
--   T3 seq 回退提交 → 被丢弃，返回当前 rev
--   T4 switch.rank=false → rank() 返回未开启，submit 仍可写
-- 末尾追加：经 agent 的 u.crossSubmit / u.crossRank 端到端可用（证明 handler 注入链路通）。

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

function M.run(db, login, gate, ws_addr, hub)
    local t = testutil.new("test_cross")
    local E = schema.errors

    t.check(hub ~= nil, "T0 hub address injected")
    if not hub then return t.result() end

    -- 用唯一 rankKey 隔离，避免与常驻/其他进程快照串味
    local KEY = "cross_test_rank"

    -- 干净起点：关掉前次可能残留的开关（幂等；本测试进程 hub 是新起的）
    skynet.call(hub, "lua", "set_switch", "rank", true)

    -- ===== T1 合并正确 + 按分数降序 =====
    local r1 = skynet.call(hub, "lua", "submit", 1, 1, 100, KEY, "u1", 10)
    local r2 = skynet.call(hub, "lua", "submit", 1, 2, 200, KEY, "u2", 30)
    t.check(r1.ok and r2.ok, "T1 two zones submit ok")
    local page = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20)
    t.eq(#page.rows, 2, "T1 merged 2 rows from 2 zones")
    t.eq(page.rows[1].uid, "u2", "T1 top is higher score")
    t.eq(page.rows[1].score, 30, "T1 top score 30")
    t.eq(page.rows[1].rank, 1, "T1 top rank = 1")

    -- ===== T2 幂等：同 (sid, seq) 重复提交不改分数与 rev =====
    local rev_before = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20).rev
    local dup = skynet.call(hub, "lua", "submit", 1, 2, 200, KEY, "u2", 99999)
    t.eq(dup.reason, "duplicate", "T2 duplicate reason")
    local rev_after = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20).rev
    t.eq(rev_after, rev_before, "T2 rev unchanged on duplicate")
    local page2 = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20)
    local u2_score
    for _, row in ipairs(page2.rows) do if row.uid == "u2" then u2_score = row.score end end
    t.eq(u2_score, 30, "T2 score unchanged on duplicate")

    -- ===== T3 乱序丢弃：seq 回退被拒，rev 不变 =====
    local rev_before3 = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20).rev
    local stale = skynet.call(hub, "lua", "submit", 1, 2, 150, KEY, "u2", 77777)
    t.eq(stale.reason, "stale_seq", "T3 stale seq discarded")
    t.eq(stale.rev, rev_before3, "T3 rev unchanged on stale")
    local page3 = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20)
    local u2_score3
    for _, row in ipairs(page3.rows) do if row.uid == "u2" then u2_score3 = row.score end end
    t.eq(u2_score3, 30, "T3 score unchanged on stale")

    -- ===== T4 三级开关：rank 查询关闭，submit 仍可写 =====
    skynet.call(hub, "lua", "set_switch", "rank", false)
    local off = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20)
    t.eq(off.ok, false, "T4 rank query disabled")
    t.eq(off.enabled, false, "T4 enabled=false")
    t.eq(off.reason, "rank_disabled", "T4 readable reason (gray entry)")
    local rev_before4 = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20).rev
    local write_when_off = skynet.call(hub, "lua", "submit", 1, 3, 300, KEY, "u3", 50)
    t.check(write_when_off.ok, "T4 submit still writable when switch off")
    t.eq(write_when_off.enabled, false, "T4 submit reports switch state")
    local rev_after4 = skynet.call(hub, "lua", "rank", 1, KEY, 1, 20).rev
    t.check(rev_after4 > rev_before4, "T4 write actually advanced rev while off")
    skynet.call(hub, "lua", "set_switch", "rank", true)

    -- ===== 端到端：经 agent 的 u.crossSubmit / u.crossRank =====
    local name = "cross_batch@test"
    local code, uid = skynet.call(login, "lua", "create_account", name, PWD)
    t.eq(code, E.OK, "E2E create account")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, name, uid)
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)
    skynet.call(agent, "lua", "set_hub", hub)

    local KEY2 = "cross_e2e_rank"
    local sr = act(agent, 1, "u.crossSubmit", { KEY2, 100 })
    t.eq(sr.err, E.OK, "E2E crossSubmit ok")
    t.eq(sr.result.ok, true, "E2E crossSubmit result.ok")
    t.check(sr.result.rank ~= nil, "E2E crossSubmit returns rank")
    local qr = act(agent, 2, "u.crossRank", { KEY2, 1 })
    t.eq(qr.err, E.OK, "E2E crossRank ok")
    t.eq(qr.result.enabled, true, "E2E crossRank enabled")
    t.check(qr.result.rows and #qr.result.rows >= 1, "E2E crossRank has rows")
    t.check(qr.result.me ~= nil, "E2E crossRank fills me via ctx.uid")

    -- 未注入 hub 的 agent 应给可读错误，不崩
    local agent2 = skynet.newservice("agent")
    skynet.call(agent2, "lua", "init", db, euid)
    local nohub = act(agent2, 3, "u.crossSubmit", { KEY2, 1 })
    t.eq(nohub.result.reason, "hub_not_injected", "E2E missing hub -> readable reason")

    -- settle 只留接口占位（CROSS_SERVER §4.4）：返回结构化 not_implemented，不写半成品
    local settle = skynet.call(hub, "lua", "settle")
    t.eq(settle.ok, false, "settle not implemented")
    t.eq(settle.reason, "not_implemented", "settle reason (interface reserved)")

    t.check(skynet.call(db, "lua", "flush"), "flush")
    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
