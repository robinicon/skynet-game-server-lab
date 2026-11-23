-- test_gate.lua — 阶段 1 端到端：TCP 帧 → legacy JSON → 归一化 → agent → legacy 回包
--
-- 覆盖：
--   T1 首包 u.create 登录 + 初始快照
--   T2 业务动作 op 原样往返 + delta 随回包下发
--   T3 未知 op 返回 UNKNOWN_OP(-100)
--   T4 连续两包（粘包）各自独立回应，session 对齐
--   T5 断线清理与 u.login 重连（实体不重置）
--   T6 首包非法直接拒绝

local skynet    = require "skynet"
local message   = require "shared.message"
local schema    = require "shared.schema"
local testutil  = require "shared.testutil"
local gateclient = require "gateclient"

local M = {}

function M.run(db, login, gate)
    local t = testutil.new("test_gate")
    local addr = "127.0.0.1"
    local port = tonumber(os.getenv("CH13_GATE_PORT")) or 9813
    local pwd  = "0123456789abcdef0123456789abcdef"
    local account = "gateplayer@test"

    -- ===== T1: u.create 首包 + 快照 =====
    local fd = gateclient.connect(addr, port)
    t.check(fd and fd > 0, "T1 tcp connect")

    local resp, sid = gateclient.request(fd, {
        id = 11, type = "c", scope = "c", op = "u.create",
        params = { account, pwd },
    }, 11)
    t.check(resp ~= nil, "T1 create response received")
    t.eq(resp and resp.op, "u.create", "T1 legacy op preserved on response")
    t.eq(resp and resp.type, "r", "T1 response type is r")
    t.eq(resp and resp.error, schema.errors.OK, "T1 create ok")
    t.check(resp and resp.params and resp.params.ok == true, "T1 ok flag")
    t.check(resp and resp.params and type(resp.params.token) == "string", "T1 token issued")
    t.eq(sid, 11, "T1 session echoed on wire")

    local snap_text, snap_sid = gateclient.read_pack(fd)
    t.check(snap_text ~= nil, "T1 snapshot frame received")
    local snap = message.decode(snap_text or "")
    t.eq(snap and snap.op, "u.snapshot", "T1 legacy snapshot op")
    t.eq(snap_sid, 11, "T1 snapshot session aligned")
    t.check(snap and snap.params and snap.params.rev >= 1, "T1 snapshot rev")
    t.eq(snap and schema.get(snap.params.partitions.base, "account"), account,
        "T1 snapshot carries abstract account field")
    t.eq(skynet.call(gate, "lua", "online_count"), 1, "T1 online count is 1")

    -- ===== T2: 业务动作，op 原样往返 + delta =====
    local hero = gateclient.request(fd, {
        id = 20, type = "c", scope = "c", op = "u.dev.heroLv",
        params = { "h9", 4 },
    }, 20)
    t.eq(hero and hero.op, "u.dev.heroLv", "T2 action op round-trips")
    t.eq(hero and hero.error, schema.errors.OK, "T2 action ok")
    t.eq(hero and hero.params and hero.params.ok, true, "T2 result ok")
    local delta = hero and hero.params and hero.params.delta
    t.check(delta ~= nil, "T2 delta embedded in legacy response")
    t.eq(delta and delta.values[schema.fid("heroes")].h9.lv, 4, "T2 delta carries fid-keyed hero change")

    local buy = gateclient.request(fd, {
        id = 21, type = "c", scope = "c", op = "u.dev.itemAdd", params = { 1001, 2 },
    }, 21)
    t.eq(buy and buy.op, "u.dev.itemAdd", "T2 second action op round-trips")
    t.eq(buy and buy.error, schema.errors.OK, "T2 second action ok")
    t.eq(buy and buy.params.delta.values[schema.fid("bag")][1001], 2, "T2 bag delta")

    -- ===== T3: 未知 op =====
    local bad = gateclient.request(fd, {
        id = 30, type = "c", scope = "c", op = "u.noSuchOp", params = {},
    }, 30)
    t.eq(bad and bad.op, "u.noSuchOp", "T3 unknown op echoed for diagnostics")
    t.eq(bad and bad.error, schema.errors.UNKNOWN_OP, "T3 unknown op returns -100")
    t.eq(bad and bad.params.ok, false, "T3 unknown op result not ok")

    -- ===== T4: 粘包（两个请求连续写入，不等回包） =====
    gateclient.send(fd, { id = 40, type = "c", scope = "c", op = "u.avatar_info", params = {} }, 40)
    gateclient.send(fd, { id = 41, type = "c", scope = "c", op = "u.avatar_info", params = {} }, 41)
    local text1, sid1 = gateclient.read_pack(fd)
    local text2, sid2 = gateclient.read_pack(fd)
    t.eq(sid1, 40, "T4 first pipelined session")
    t.eq(sid2, 41, "T4 second pipelined session")
    local r1 = message.decode(text1 or "")
    local r2 = message.decode(text2 or "")
    t.eq(r1 and r1.id, 40, "T4 first pipelined legacy id")
    t.eq(r2 and r2.id, 41, "T4 second pipelined legacy id")
    t.eq(r1 and r1.op, "u.avatar_info", "T4 first op preserved")
    t.eq(r2 and r2.op, "u.avatar_info", "T4 second op preserved")

    -- ===== T5: 断线 + u.login 重连，实体不重置 =====
    gateclient.close(fd)
    skynet.sleep(10)
    t.eq(skynet.call(gate, "lua", "online_count"), 0, "T5 online count drops after close")

    local fd2 = gateclient.connect(addr, port)
    t.check(fd2 and fd2 > 0, "T5 reconnect tcp")
    local login_resp = gateclient.request(fd2, {
        id = 50, type = "c", scope = "c", op = "u.login", params = { account, pwd },
    }, 50)
    t.eq(login_resp and login_resp.op, "u.login", "T5 legacy login op")
    t.eq(login_resp and login_resp.error, schema.errors.OK, "T5 login ok")
    local snap2_text = gateclient.read_pack(fd2)
    local snap2 = message.decode(snap2_text or "")
    t.eq(schema.get(snap2.params.partitions.hero, "heroes").h9.lv, 4,
        "T5 reconnect reuses entity, hero level preserved")
    t.eq(schema.get(snap2.params.partitions.item, "bag")[1001], 2,
        "T5 reconnect preserves bag")
    t.eq(skynet.call(gate, "lua", "online_count"), 1, "T5 online count back to 1")
    gateclient.close(fd2)

    -- ===== T6: 首包非法直接拒绝 =====
    local fd3 = gateclient.connect(addr, port)
    local bad_first = gateclient.request(fd3, {
        id = 60, type = "c", scope = "c", op = "u.heroUpdateLv", params = { "h1", 1 },
    }, 60)
    t.eq(bad_first and bad_first.error, schema.errors.UNKNOWN_OP,
        "T6 first packet must be login/create")
    gateclient.close(fd3)
    skynet.sleep(10)
    t.eq(skynet.call(gate, "lua", "online_count"), 0, "T6 rejected connection not counted")

    t.check(skynet.call(db, "lua", "flush"), "gate flow snapshot flushed")
    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
