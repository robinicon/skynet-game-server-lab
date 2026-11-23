-- test/test_ws_gate.lua — P0 验收：WebSocket 入口
--
-- 覆盖：
--   W1 HELLO 鉴权 → ACTION_RES(aid=1) + SNAPSHOT（9 个可下发 fid）
--   W2 ACTION_REQ 动作 → ACTION_RES + 独立 DELTA 帧（wire=2 不嵌回包）
--   W3 PING → PING(pong)
--   W4 未知 aid → UNKNOWN_OP
--   W5 未登录直接 REQ → BAD_STATE
--   W6 带 token 重连 → 复用 agent，rev 不回退
--   W7 顶号 → 旧连接收到 kicked，新连接接管
--   W8 grace 到期 → expire 落盘，会话释放
--
-- 传输层用 skynet 自带的 http.websocket 客户端，与 Unity/小游戏走的是同一条帧路径。

local skynet    = require "skynet"
local websocket = require "http.websocket"
local message   = require "shared.message"
local schema    = require "shared.schema"
local testutil  = require "shared.testutil"

local M = {}

local KIND = message.KIND
local PWD  = "0123456789abcdef0123456789abcdef"

local function connect(port)
    return websocket.connect("ws://127.0.0.1:" .. tostring(port))
end

local function send(id, tbl)
    websocket.write(id, message.encode(tbl), "text")
end

local function recv(id)
    -- 连接可能已被对端关闭：read 会抛 socket_error，这里统一折成 nil，
    -- 让断言失败而不是让整个测试服务崩溃
    local ok, text = pcall(websocket.read, id)
    if not ok or not text or text == false then return nil end
    local ok2, env = pcall(message.decode, text)
    if not ok2 then return nil end
    return env
end

local function hello(id, account, token, seq)
    local params = { account = account, password = PWD }
    if token then params.token = token end
    send(id, { kind = KIND.HELLO, seq = seq or 1, wire = 2, params = params })
end

-- 快照里实际下发的 fid 个数（on_demand 未订阅、none 不下发）
local function count_fids(snap)
    local n = 0
    for _, part in pairs(snap.partitions or {}) do
        for _ in pairs(part) do n = n + 1 end
    end
    return n
end

function M.run(db, login, gate, ws_addr)
    local t = testutil.new("test_ws_gate")

    t.check(ws_addr ~= nil, "W0 ws_gate service address provided")
    if not ws_addr then return t.result() end
    local port = tonumber(os.getenv("CH13_WS_PORT")) or 9814
    skynet.call(ws_addr, "lua", "set_grace", 30)   -- 0.3s，避免用例互相等

    -- ===== W1: HELLO → 回执 + 快照 =====
    local account = "wsplayer@test"
    local id1 = connect(port)
    t.check(id1 and id1 > 0, "W1 ws handshake")

    hello(id1, account, nil, 7)
    local ack = recv(id1)
    t.eq(ack and ack.kind, KIND.ACTION_RES, "W1 hello ack kind ACTION_RES")
    t.eq(ack and ack.aid, 1, "W1 hello ack aid=1 (u.login)")
    t.eq(ack and ack.err, schema.errors.OK, "W1 hello ok")
    t.eq(ack and ack.seq, 7, "W1 hello seq echoed")
    t.check(ack and ack.result and ack.result.ok == true, "W1 hello result ok")
    t.check(ack and ack.result and type(ack.result.token) == "string", "W1 token issued")
    t.check(ack and ack.result and ack.result.wire == 2, "W1 wire negotiated to 2")

    local snap = recv(id1)
    t.eq(snap and snap.kind, KIND.SNAPSHOT, "W1 snapshot frame follows ack")
    t.check(snap and (snap.rev or 0) >= 1, "W1 snapshot rev >= 1")
    -- 新实体只初始化 uid/account/level/gold 四个字段；on_demand 与 none 不下发
    t.eq(snap and count_fids(snap), 4, "W1 snapshot carries 4 initialized fids")
    t.eq(snap and schema.get(snap.partitions.base, "account"), account,
        "W1 snapshot carries abstract account field")
    t.check(snap and schema.get(snap.partitions.base, "uid") ~= nil,
        "W1 snapshot carries uid field")

    local token = ack and ack.result and ack.result.token
    local rev_after_login = snap and snap.rev
    local stats = skynet.call(ws_addr, "lua", "stats")
    t.eq(stats.online, 1, "W1 online = 1")
    t.eq(stats.active, 1, "W1 session active")

    -- ===== W2: 动作 → ACTION_RES + 独立 DELTA =====
    send(id1, { kind = KIND.ACTION_REQ, seq = 21, aid = 4,
                params = { itemId = 1001, count = 2 } })
    local res = recv(id1)
    t.eq(res and res.kind, KIND.ACTION_RES, "W2 action res kind")
    t.eq(res and res.aid, 4, "W2 action res aid")
    t.eq(res and res.seq, 21, "W2 action res seq")
    t.eq(res and res.err, schema.errors.OK, "W2 action ok")
    t.check(res and res.delta == nil, "W2 delta is not embedded in ACTION_RES")
    local delta = recv(id1)
    t.eq(delta and delta.kind, KIND.DELTA, "W2 delta arrives as its own frame")
    t.eq(delta and delta.base_rev, rev_after_login, "W2 delta base_rev = snapshot rev")
    t.check(delta and delta.rev > delta.base_rev, "W2 delta rev advances")
    local bag_fid = schema.fid("bag")
    t.eq(delta and delta.values and delta.values[bag_fid] and delta.values[bag_fid][1001], 2,
        "W2 delta carries fid-keyed bag change")

    -- 英雄动作：验证第二个 fid 键（fid=6）
    send(id1, { kind = KIND.ACTION_REQ, seq = 22, aid = 3,
                params = { heroId = "h9", lv = 4 } })
    local res2 = recv(id1)
    t.eq(res2 and res2.err, schema.errors.OK, "W2b hero action ok")
    local delta2 = recv(id1)
    local hero_fid = schema.fid("heroes")
    t.eq(delta2 and delta2.values[hero_fid] and delta2.values[hero_fid].h9.lv, 4,
        "W2b delta carries hero fid 6")

    -- ===== W3: PING =====
    send(id1, { kind = KIND.PING, seq = 31 })
    local pong = recv(id1)
    t.eq(pong and pong.kind, KIND.PING, "W3 ping echoes kind PING")
    t.check(pong and pong.params and pong.params.pong == true, "W3 pong flag")

    -- ===== W4: 未知 aid =====
    send(id1, { kind = KIND.ACTION_REQ, seq = 41, aid = 999, params = {} })
    local bad = recv(id1)
    t.eq(bad and bad.err, schema.errors.UNKNOWN_OP, "W4 unknown aid → UNKNOWN_OP")
    t.eq(bad and bad.seq, 41, "W4 unknown aid echoes seq")

    -- ===== W5: 未登录直接 REQ =====
    local id2 = connect(port)
    t.check(id2 and id2 > 0, "W5 second ws handshake")
    send(id2, { kind = KIND.ACTION_REQ, seq = 51, aid = 4, params = { itemId = 1001, count = 1 } })
    local need_login = recv(id2)
    t.eq(need_login and need_login.err, schema.errors.BAD_STATE, "W5 REQ before HELLO → BAD_STATE")

    -- ===== W6: 带 token 重连 =====
    -- 直接关掉连接；服务端会在 disconnect 时挂起会话。不主动排空残余帧：
    -- socket 已关，继续 read 只会抛 socket_error。
    pcall(websocket.close, id1)
    skynet.sleep(15)
    local id3 = connect(port)
    t.check(id3 and id3 > 0, "W6 reconnect handshake")
    hello(id3, account, token, 61)
    local ack3 = recv(id3)
    t.eq(ack3 and ack3.err, schema.errors.OK, "W6 reconnect ok")
    t.eq(ack3 and ack3.result and ack3.result.token, token, "W6 token preserved across reconnect")
    local snap3 = recv(id3)
    t.check(snap3 and (snap3.rev or 0) >= (delta2 and delta2.rev or 0),
        "W6 snapshot rev does not regress after reconnect")
    local bag3 = snap3 and snap3.partitions and snap3.partitions.item
    t.eq(bag3 and bag3[bag_fid] and bag3[bag_fid][1001], 2,
        "W6 entity state survives reconnect (same agent)")

    -- ===== W7: 顶号 =====
    local id4 = connect(port)
    t.check(id4 and id4 > 0, "W7 takeover handshake")
    hello(id4, account, nil, 71)
    local ack4 = recv(id4)
    t.eq(ack4 and ack4.err, schema.errors.OK, "W7 new login ok")

    local kicked = recv(id3)
    t.eq(kicked and kicked.err, schema.errors.BAD_STATE, "W7 old connection receives kick frame")
    t.check(kicked and kicked.result and tostring(kicked.result.reason):find("kicked") ~= nil,
        "W7 kick reason mentions kicked")
    skynet.sleep(10)

    local st7 = skynet.call(ws_addr, "lua", "stats")
    t.eq(st7.takeover, 1, "W7 takeover counted")
    t.eq(st7.active, 1, "W7 exactly one active session after takeover")

    -- ===== W8: grace 到期 → expire =====
    skynet.call(ws_addr, "lua", "set_grace", 5)   -- 50ms
    local id5 = connect(port)
    hello(id5, "ws_expire@test", nil, 81)
    local ack5 = recv(id5)
    t.eq(ack5 and ack5.err, schema.errors.OK, "W8 expire-account login ok")
    recv(id5)   -- snapshot

    websocket.close(id5)
    skynet.sleep(30)   -- 0.3s，远超 50ms grace

    local exp = skynet.call(ws_addr, "lua", "last_expire")
    t.check(exp ~= nil, "W8 grace expiry recorded")
    t.check(exp and exp.ok == true, "W8 expire flushed state")
    t.check(exp and type(exp.written) == "table", "W8 expire reports written partitions")

    local st8 = skynet.call(ws_addr, "lua", "stats")
    t.check(st8.expire_count >= 1, "W8 expire count recorded")
    t.check(st8.suspended == 0, "W8 no session left suspended")

    -- ===== W9: token 免密续连（U1 新增）=====
    -- 客户端只持久化 token（不存明文密码），切后台回来必须能用 token 单独完成 HELLO。
    -- 原实现无条件要求 password 非空，这条设计在服务端不成立，W9 就是它的回归守卫。
    -- 注意：HELLO 只允许在 handshake 态发一次，所以续连必须换新连接（与真实客户端一致）。
    skynet.call(ws_addr, "lua", "set_grace", 30)
    local id6 = connect(port)
    local acc6 = "ws_token_only@test"
    hello(id6, acc6, nil, 91)
    local ack6 = recv(id6)
    t.eq(ack6 and ack6.err, schema.errors.OK, "W9 password login ok")
    local token6 = ack6 and ack6.result and ack6.result.token
    local uid6 = ack6 and ack6.result and ack6.result.uid
    local snap6 = recv(id6)
    local rev6 = snap6 and snap6.rev or 0
    t.check(token6 ~= nil and uid6 ~= nil, "W9 token+uid issued")

    pcall(websocket.close, id6)
    skynet.sleep(10)
    local id6c = connect(port)
    websocket.write(id6c, message.encode({
        kind = KIND.HELLO, seq = 92, wire = 2,
        params = { account = acc6, token = token6 },   -- 注意：无 password
    }), "text")
    local ack6b = recv(id6c)
    t.eq(ack6b and ack6b.err, schema.errors.OK, "W9 token-only HELLO accepted (no password)")
    t.eq(ack6b and ack6b.result and ack6b.result.uid, uid6, "W9 same uid by token")
    local snap6b = recv(id6c)
    t.check(snap6b and (snap6b.rev or 0) >= rev6, "W9 rev not regressed after token hello")

    -- ===== W10: 无效 token + 无密码 → BAD_ACCOUNT（不能被当成登录成功）=====
    skynet.call(ws_addr, "lua", "set_grace", 5)   -- 50ms：让 W11 的 agent 尽快过期
    pcall(websocket.close, id6c)
    skynet.sleep(10)
    local id6b = connect(port)
    websocket.write(id6b, message.encode({
        kind = KIND.HELLO, seq = 94, wire = 2,
        params = { account = "nobody@test", token = "deadbeefdeadbeefdeadbeefdeadbeef" },
    }), "text")
    local bad_tok = recv(id6b)
    t.eq(bad_tok and bad_tok.err, schema.errors.BAD_ACCOUNT, "W10 invalid token without password → BAD_ACCOUNT")
    pcall(websocket.close, id6b)

    -- ===== W11: 超 grace（agent 已退出）后 token 免密重连，rev 与状态仍在 =====
    skynet.sleep(30)
    local id7 = connect(port)
    websocket.write(id7, message.encode({
        kind = KIND.HELLO, seq = 95, wire = 2,
        params = { token = token6 },   -- 连 account 都不给：完全靠 token 找回
    }), "text")
    local ack7 = recv(id7)
    t.eq(ack7 and ack7.err, schema.errors.OK, "W11 token-only HELLO after expiry ok")
    t.eq(ack7 and ack7.result and ack7.result.uid, uid6,
        "W11 rebuilds the same entity from token (no account given)")
    local snap7 = recv(id7)
    t.check(snap7 and (snap7.rev or 0) >= rev6,
        "W11 rev survives agent expiry (persisted, not reset)")
    t.check(snap7 and snap7.partitions and snap7.partitions.base ~= nil,
        "W11 snapshot still carries base partition")

    -- 收尾：reset_sessions 会关闭全部连接并释放会话，不需再逐个 close
    -- （重复 close 已关闭的 fd 会让 socket 层报 Broken pipe 并杀掉调用方服务）
    skynet.call(ws_addr, "lua", "reset_sessions", { grace = 300 })
    skynet.sleep(10)

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
