-- test_login_flow.lua — test 渠道换票 → agent 加载 → 动作 → delta → 重连读回

local skynet   = require "skynet"
local md5      = require "md5"
local schema   = require "shared.schema"
local message  = require "shared.message"
local testutil = require "shared.testutil"

local M = {}

function M.run(db, login)
    local t = testutil.new("test_login_flow")
    local client_md5 = "0123456789abcdef0123456789abcdef"

    local code, uid = skynet.call(login, "lua", "create_account", "player1@test", client_md5)
    t.eq(code, schema.errors.OK, "create account")
    t.check(uid > 0, "account uid assigned")

    local ok_code, ok_uid, token = skynet.call(login, "lua", "auth", "player1@test", client_md5)
    t.eq(ok_code, schema.errors.OK, "auth correct password")
    t.eq(ok_uid, uid, "auth uid matches account")
    t.check(type(token) == "string" and #token > 0, "token issued")

    local bad_code = skynet.call(login, "lua", "auth", "player1@test", "wrong-pass")
    t.eq(bad_code, schema.errors.BAD_PASSWORD, "wrong password rejected")

    local tcode, tuid = skynet.call(login, "lua", "login_by_token", token)
    t.eq(tcode, schema.errors.OK, "token login")
    t.eq(tuid, uid, "token maps to same uid")

    -- 模拟 login_handler：按账号 uid 创建/加载实体并绑定 agent
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, "player1@test", uid)
    t.eq(euid, uid, "entity uid equals account uid")

    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)
    local snap = skynet.call(agent, "lua", "snapshot")
    t.eq(snap.kind, message.KIND.SNAPSHOT, "snapshot kind")
    t.eq(schema.get(snap.partitions.base, "account"), "player1@test", "snapshot carries account")
    t.check(snap.rev >= 1, "snapshot rev")

    local env = message.normalize_in({ id = 100, op = "u.dev.heroLv", params = { "h1", 3 } })
    local resp = skynet.call(agent, "lua", "dispatch", env)
    t.eq(resp.kind, message.KIND.ACTION_RES, "action response kind")
    t.eq(resp.err, schema.errors.OK, "action success")
    t.check(resp.result.ok, "result ok flag")
    t.eq(resp.delta.kind, message.KIND.DELTA, "response carries delta")
    t.eq(resp.delta.rev, snap.rev + 1, "delta rev advances")

    local state = {}
    for pid, data in pairs(snap.partitions) do
        for fid, v in pairs(data) do state[fid] = v end
    end
    state.__rev = snap.rev
    t.check(message.apply_delta(state, resp.delta), "client applies delta")
    t.eq(schema.get(state, "heroes").h1.lv, 3, "hero level after delta")

    local env2 = message.normalize_in({ id = 101, op = "u.dev.itemAdd", params = { 1001, 2 } })
    local resp2 = skynet.call(agent, "lua", "dispatch", env2)
    t.eq(resp2.err, schema.errors.OK, "item add action success")
    t.eq(resp2.delta.values[schema.fid("bag")][1001], 2, "bag change delta")

    local legacy = message.to_legacy(resp2)
    t.eq(legacy.op, "u.dev.itemAdd", "legacy response op restored")

    local final = skynet.call(agent, "lua", "state")
    t.eq(schema.get(final, "bag")[1001], 2, "state reload sees item add result")
    t.check(skynet.call(db, "lua", "flush"), "flush after login flow")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
