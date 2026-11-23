-- test_reconnect.lua — 阶段 3 端到端：断线挂起 / 重连恢复 / 超时落盘 / 顶号
--
-- 覆盖：
--   T1 登录 → 变更 → 断线挂起（agent 保留，online 归零）
--   T2 grace 内带 token 换 fd 重连（同一 agent、数据保留、token 沿用）
--   T3 超时未重连 → expire 落盘 → 会话清除 → 重新登录数据不丢、agent 换新
--   T4 同账号再次登录顶号：旧 fd 失效、在线数=1、新连接可用、状态保留

local skynet     = require "skynet"
local message    = require "shared.message"
local schema     = require "shared.schema"
local testutil   = require "shared.testutil"
local gateclient = require "gateclient"

local M = {}

local function request(fd, id, op, params)
    return gateclient.request(fd, {
        id = id, type = "c", scope = "c", op = op, params = params,
    }, id)
end

function M.run(db, login, gate)
    local t = testutil.new("test_reconnect")
    skynet.call(gate, "lua", "reset_sessions")
    skynet.call(gate, "lua", "set_grace", 30)  -- 0.3s，测试用短窗口

    local addr = "127.0.0.1"
    local port = tonumber(os.getenv("CH13_GATE_PORT")) or 9813
    local pwd = "abcdef0123456789abcdef0123456789"
    local account = "reconnect@test"

    -- ===== T1: 登录 → 变更 → 断线挂起 =====
    local fd1 = gateclient.connect(addr, port)
    t.check(fd1 and fd1 > 0, "T1 tcp connect")

    local r1 = request(fd1, 1, "u.create", { account, pwd })
    t.eq(r1 and r1.error, schema.errors.OK, "T1 create ok")
    local uid = r1 and r1.params and r1.params.uid
    local token = r1 and r1.params and r1.params.token
    t.check(type(uid) == "number" and uid > 0, "T1 entity uid issued")
    t.check(type(token) == "string" and #token > 0, "T1 session token issued")

    local snap1 = message.decode(gateclient.read_pack(fd1) or "")
    t.eq(snap1 and snap1.op, "u.snapshot", "T1 snapshot frame")

    local act = request(fd1, 2, "u.dev.heroLv", { "rc-h1", 3 })
    t.eq(act and act.error, schema.errors.OK, "T1 hero action ok")

    local s1 = skynet.call(gate, "lua", "session_of", uid)
    t.eq(s1 and s1.state, "active", "T1 session active")
    local agent1 = s1 and s1.agent
    t.check(agent1 ~= nil, "T1 agent bound")

    gateclient.close(fd1)
    skynet.sleep(8)
    t.eq(skynet.call(gate, "lua", "online_count"), 0, "T1 online drops on disconnect")
    local st1 = skynet.call(gate, "lua", "session_stats")
    t.eq(st1.suspended, 1, "T1 session suspended")
    t.eq(st1.active, 0, "T1 no active session")
    local s1b = skynet.call(gate, "lua", "session_of", uid)
    t.eq(s1b and s1b.state, "suspended", "T1 session_of reports suspended")
    t.eq(s1b and s1b.agent, agent1, "T1 agent kept while suspended")

    -- ===== T2: grace 内带 token 换 fd 重连 =====
    local fd2 = gateclient.connect(addr, port)
    t.check(fd2 and fd2 > 0, "T2 reconnect tcp")
    local r2 = request(fd2, 3, "u.login", { account, pwd, token })
    t.eq(r2 and r2.error, schema.errors.OK, "T2 token login ok")
    t.eq(r2 and r2.params.uid, uid, "T2 same entity uid")
    t.eq(r2 and r2.params.token, token, "T2 token reused")

    local snap2 = message.decode(gateclient.read_pack(fd2) or "")
    t.check(snap2 ~= nil, "T2 snapshot frame after resume")
    t.eq(schema.get(snap2 and snap2.params.partitions.hero, "heroes")["rc-h1"].lv, 3,
        "T2 hero level preserved after resume")

    local s2 = skynet.call(gate, "lua", "session_of", uid)
    t.eq(s2 and s2.state, "active", "T2 session active again")
    t.eq(s2 and s2.agent, agent1, "T2 same agent reused")
    t.eq(skynet.call(gate, "lua", "online_count"), 1, "T2 online back to 1")

    -- ===== T3: 超时落盘 + 重新登录 =====
    gateclient.close(fd2)
    skynet.sleep(5)
    local before = skynet.call(gate, "lua", "session_stats")
    t.eq(before.suspended, 1, "T3 suspended before grace expiry")

    skynet.sleep(45)  -- grace=30 ticks(0.3s) + 余量
    local st3 = skynet.call(gate, "lua", "session_stats")
    t.eq(st3.suspended, 0, "T3 suspended cleared after grace")
    t.eq(st3.active, 0, "T3 no active session")
    t.eq(st3.expire_count, before.expire_count + 1, "T3 one expire recorded")

    local exp = skynet.call(gate, "lua", "last_expire")
    t.eq(exp and exp.uid, uid, "T3 expire targets same uid")
    t.eq(exp and exp.ok, true, "T3 expire save ok")
    t.check(exp and exp.written and #exp.written > 0, "T3 expire wrote dirty partitions")
    t.eq(skynet.call(gate, "lua", "session_of", uid), nil, "T3 session removed after expire")
    local dstats = skynet.call(db, "lua", "stats")
    t.check(dstats and dstats.last_written and #dstats.last_written > 0,
        "T3 db last_written non-empty")

    local fd3 = gateclient.connect(addr, port)
    local r3 = request(fd3, 4, "u.login", { account, pwd })
    t.eq(r3 and r3.error, schema.errors.OK, "T3 relogin ok after expire")
    local snap3 = message.decode(gateclient.read_pack(fd3) or "")
    t.check(snap3 ~= nil, "T3 snapshot on relogin")
    t.eq(schema.get(snap3 and snap3.params.partitions.hero, "heroes")["rc-h1"].lv, 3,
        "T3 hero persisted across expire")
    local s3 = skynet.call(gate, "lua", "session_of", uid)
    t.check(s3 and s3.agent ~= agent1, "T3 new agent after expire")

    -- ===== T4: 顶号 =====
    local before_takeover = skynet.call(gate, "lua", "session_stats").takeover
    local fd4 = gateclient.connect(addr, port)
    local r4 = request(fd4, 5, "u.login", { account, pwd })
    t.eq(r4 and r4.error, schema.errors.OK, "T4 second login ok")
    local snap4 = message.decode(gateclient.read_pack(fd4) or "")
    t.check(snap4 ~= nil, "T4 snapshot on takeover")
    t.eq(skynet.call(gate, "lua", "online_count"), 1, "T4 only one online connection")

    local s4 = skynet.call(gate, "lua", "session_of", uid)
    t.eq(s4 and s4.state, "active", "T4 session active")
    t.eq(s4 and s4.agent, s3 and s3.agent, "T4 same agent reused on takeover")
    t.check(s4 and s4.fd ~= nil, "T4 session bound to a live gate fd")
    t.eq(skynet.call(gate, "lua", "session_stats").takeover,
        before_takeover + 1, "T4 takeover counter incremented")

    local act4 = request(fd4, 6, "u.dev.itemAdd", { 1001, 2 })
    t.eq(act4 and act4.error, schema.errors.OK, "T4 new connection usable")
    t.eq(act4 and act4.params.delta.values[schema.fid("bag")][1001], 2,
        "T4 state preserved after takeover")

    gateclient.close(fd4)
    skynet.sleep(8)
    t.eq(skynet.call(gate, "lua", "online_count"), 0, "T4 online drops after close")
    t.check(skynet.call(db, "lua", "flush"), "reconnect flow snapshot flushed")
    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
