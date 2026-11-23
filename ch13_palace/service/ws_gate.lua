-- service/ws_gate.lua — WebSocket 网关（Unity / 微信小游戏入口）
--
-- 与 gated（裸 TCP + netpack + legacy JSON）并存，互不影响：
--
--   Unity / 小游戏  ── ws://:9814 ──►  ws_gate  ┐
--   老工具          ── tcp://:9813 ─►  gated    ┴─► login / agent（同一套 schema 与 handler）
--
-- 为什么不能复用 gated 的帧：Cocos/Unity/小游戏只能 WebSocket，且小游戏只允许 wss
-- （TLS 由 nginx 终止，落到本服务仍是明文 ws）。所以这里只需要换个"帧的外壳"。
--
-- 帧内容：纯文本 JSON，7 种 kind（见 shared/message.lua）。不做 zlib —— 便于抓包，
-- M1~M3 的数据量下体积不显著；需要压体积时加 clib/zlib.c，不改协议。
--
-- 会话语义与 gated 对齐（这层不能省，否则切后台就掉线）：
--   active     —— fd 在线
--   suspended  —— 断线挂起，agent 保留，grace 窗口内可恢复
--   顶号        —— 同 uid 新连接先摘除旧 fd，旧连接的 disconnect 不误伤新会话
--   超时        —— grace 到期 agent.expire 落盘，然后 shutdown
-- 全部状态在本服务内，skynet 单服务串行 + 每连接一个协程，天然无锁。
--
-- 注意：不需要给 agent 加 transport 抽象。agent 只 return 结果，发包在网关侧。

local skynet    = require "skynet"
local socket    = require "skynet.socket"
local websocket = require "http.websocket"
local message   = require "shared.message"
local schema    = require "shared.schema"

local CMD = {}

local db_svc, login_svc
local hub_svc            -- P0.5：跨服中心地址，由 main 注入；建 agent 时透传
local listen_fd
local grace_ticks = 300   -- 3 秒（skynet.timeout 单位 0.01s）

local conns    = {}  -- fd  → conn   （连接记录）
local sessions = {}  -- uid → sess   （会话记录，跨连接存活）
local tokens   = {}  -- token → sess

local online   = 0
local takeover = 0
local expire_log = {}
local stat = { hello = 0, frames_in = 0, frames_out = 0, bad_frames = 0 }

-- 前向声明
local accept_one, make_handle, on_disconnect, arm_grace, handle_env

-- ========== 发送 ==========

local function send_env(c, env)
    if not c or not c.alive then return false end
    local ok, text = pcall(message.encode, env)
    if not ok then
        skynet.error("[ws_gate] encode failed: " .. tostring(text))
        return false
    end
    local ok2, err = pcall(websocket.write, c.fd, text, "text")
    if not ok2 then
        -- 连接已消失（对端 close / 顶号）：不抛出，等 accept 循环收尾
        skynet.error(string.format("[ws_gate] write failed fd=%d err=%s", c.fd, tostring(err)))
        return false
    end
    stat.frames_out = stat.frames_out + 1
    return true
end

local function send_err(c, seq, aid, code, reason)
    return send_env(c, {
        kind = message.KIND.ACTION_RES, seq = seq or 0, aid = aid or 0,
        err = code, result = { ok = false, reason = reason or "" },
    })
end

-- ========== 会话生命周期 ==========

-- grace 到期：落盘 + 退出 agent。gen 让旧定时器在重连后自动失效。
arm_grace = function(s)
    s.gen = (s.gen or 0) + 1
    local uid, gen = s.uid, s.gen
    skynet.timeout(grace_ticks, function()
        local cur = sessions[uid]
        if not cur or cur ~= s or cur.gen ~= gen or cur.state ~= "suspended" then return end

        local ok, res = pcall(skynet.call, s.agent, "lua", "expire")
        if ok and type(res) == "table" then
            expire_log[#expire_log + 1] = {
                uid = uid, at = skynet.time(), ok = res.ok, written = res.written or {},
            }
        else
            skynet.error(string.format("[ws_gate] expire failed uid=%d err=%s", uid, tostring(res)))
        end

        sessions[uid] = nil
        if s.token then tokens[s.token] = nil end
        pcall(skynet.send, s.agent, "lua", "shutdown")
    end)
end

on_disconnect = function(fd)
    local c = conns[fd]
    if not c then return end
    conns[fd] = nil
    c.alive = false

    local s = c.sess
    -- 只有"当前 fd 就是会话 fd"时才挂起；顶号时旧 fd 已被摘除，不能误伤新会话
    if not s or s.fd ~= fd or s.state ~= "active" then return end

    online = math.max(0, online - 1)
    s.state = "suspended"
    s.fd = nil
    pcall(skynet.call, s.agent, "lua", "suspend")
    arm_grace(s)
end

-- ========== HELLO：鉴权 + 建/复用会话 ==========

local function do_hello(c, env)
    if c.state ~= "handshake" then
        send_err(c, env.seq, 1, schema.errors.BAD_STATE, "already logged in")
        return
    end

    local p = env.params or {}
    local account, password = p.account, p.password
    if type(account) ~= "string" or account == "" then account = nil end
    local want_token = (type(p.token) == "string" and p.token ~= "") and p.token or nil

    -- U1 实测修正：token 续连优先，命中会话时不再校验密码。
    --
    -- 原实现无条件要求 account+password 非空，于是「客户端只存 token、不存明文密码」
    -- 这条设计在服务端根本不成立——切后台回来必然 BAD_ACCOUNT。客户端若为此缓存明文
    -- 密码，就是把长期凭据落进了 storage（小游戏只有 wx.setStorage，配额内明文可读）。
    --
    -- 两级查找，覆盖两种"回来"：
    --   1) 网关内存里还有会话（grace 内 / agent 未退出）→ 直接取 uid，零额外调用；
    --   2) 会话已过期或冷启动 → 问 login 服务的 login_by_token，令牌是它的凭据。
    -- 令牌在 login 服务重启后失效，那时只能退回账号密码（客户端清 token 回登录页）。
    local tok_sess = want_token and tokens[want_token] or nil
    local euid, token

    if tok_sess then
        euid = tok_sess.uid
        token = want_token
        account = account or tok_sess.account
    elseif want_token then
        local code, acc_uid, name = skynet.call(login_svc, "lua", "login_by_token", want_token)
        if code == schema.errors.OK then
            token = want_token
            account = account or name
            euid = skynet.call(db_svc, "lua", "find_entity_by_account", account)
            if not euid then
                euid = skynet.call(db_svc, "lua", "create_entity", "avatar", 0, account, acc_uid)
            end
        else
            want_token = nil          -- 失效令牌：退回账号密码路径
        end
    end

    if not euid then
        if not account or type(password) ~= "string" or password == "" then
            send_err(c, env.seq, 1, schema.errors.BAD_ACCOUNT,
                "account/password or valid token required")
            return
        end

        local code, account_uid
        code, account_uid, token = skynet.call(login_svc, "lua", "auth", account, password)
        if code == schema.errors.BAD_ACCOUNT then
            -- ws 通道单命令登录：账号不存在就顺带创建（legacy 由 u.create 承担这件事）
            local cc = skynet.call(login_svc, "lua", "create_account", account, password)
            if cc == schema.errors.OK then
                code, account_uid, token = skynet.call(login_svc, "lua", "auth", account, password)
            end
        end
        if code ~= schema.errors.OK then
            send_err(c, env.seq, 1, code, "authentication failed")
            return
        end

        -- 会话键用 entity uid（账号 uid ≠ 角色 uid，混用会导致重连永远找不回会话）
        euid = skynet.call(db_svc, "lua", "find_entity_by_account", account)
        if not euid then
            euid = skynet.call(db_svc, "lua", "create_entity", "avatar", 0, account, account_uid)
        end
    end

    local s
    if want_token then
        local cand = tokens[want_token]
        if cand and cand.uid == euid then s = cand end
    end
    if not s then
        local cand = sessions[euid]
        if cand and (cand.state == "active" or cand.state == "suspended") then s = cand end
    end

    -- 顶号：先通知并摘除旧连接；旧连接随后的 disconnect 因 s.fd 已变更而自动放过
    if s and s.state == "active" and s.fd and s.fd ~= c.fd then
        local old = conns[s.fd]
        if old then
            send_err(old, 0, 0, schema.errors.BAD_STATE, "kicked by new login")
            old.alive = false
            old.state = "kicked"
            conns[s.fd] = nil
            online = math.max(0, online - 1)
            pcall(websocket.close, s.fd)
        end
        takeover = takeover + 1
    end

    local snap
    if s then
        -- 恢复：gen 自增让旧 grace 回调失效
        s.gen = (s.gen or 0) + 1
        s.state = "active"
        s.fd = c.fd
        if s.token and s.token ~= token then tokens[s.token] = nil end
        s.token = s.token or token
        tokens[s.token] = s
        sessions[euid] = s
        c.sess, c.state = s, "active"

        skynet.call(s.agent, "lua", "set_wire", 2)
        local okr, res = pcall(skynet.call, s.agent, "lua", "resume", c.fd)
        if okr then
            snap = res
        else
            -- agent 已退出（grace 竞态）：丢掉旧会话，走新建
            skynet.error(string.format("[ws_gate] resume failed uid=%d err=%s", euid, tostring(res)))
            sessions[euid] = nil
            if s.token then tokens[s.token] = nil end
            s = nil
        end
    end

    if not s then
        local agent = skynet.newservice("agent")
        skynet.call(agent, "lua", "init", db_svc, euid)
        if hub_svc then skynet.call(agent, "lua", "set_hub", hub_svc) end
        skynet.call(agent, "lua", "set_wire", 2)
        s = { uid = euid, account = account, agent = agent, token = token,
              state = "active", fd = c.fd, gen = 0 }
        sessions[euid] = s
        tokens[token] = s
        c.sess, c.state = s, "active"
    end

    online = online + 1
    stat.hello = stat.hello + 1

    -- 登录回执：aid=1 与 legacy u.login 对齐，客户端迁移成本最低
    send_env(c, {
        kind = message.KIND.ACTION_RES, seq = env.seq or 0, aid = 1,
        err = schema.errors.OK,
        result = { ok = true, uid = euid, account = account, token = s.token, wire = 2 },
    })

    if not snap then snap = skynet.call(s.agent, "lua", "snapshot") end
    if snap then
        snap.seq = env.seq or 0
        send_env(c, snap)
    end
end

-- ========== ACTION_REQ ==========

local function do_req(c, env)
    local s = c.sess
    if not s or c.state ~= "active" then
        send_err(c, env.seq, env.aid, schema.errors.BAD_STATE, "not logged in")
        return
    end

    local aid = tonumber(env.aid) or 0
    local req = {
        kind = message.KIND.ACTION_REQ, seq = tonumber(env.seq) or 0,
        aid = aid, params = env.params or {},
    }

    local ok, resp = pcall(skynet.call, s.agent, "lua", "dispatch", req)
    if not ok or type(resp) ~= "table" then
        send_err(c, req.seq, aid, schema.errors.BAD_STATE,
            "dispatch failed: " .. tostring(resp))
        return
    end

    -- wire=2：delta 独立成帧（wire=1 才嵌在回包里）
    local delta = resp.delta
    resp.delta = nil
    send_env(c, resp)
    if delta then
        delta.seq = req.seq
        send_env(c, delta)
    end
end

-- ========== 帧分发 ==========

handle_env = function(c, env)
    local kind = tonumber(env.kind) or 0

    if kind == message.KIND.HELLO then
        do_hello(c, env)
    elseif kind == message.KIND.PING then
        send_env(c, { kind = message.KIND.PING, seq = env.seq or 0,
                      params = { pong = true, at = skynet.time() } })
    elseif kind == message.KIND.ACTION_REQ then
        do_req(c, env)
    else
        send_err(c, env.seq, env.aid, schema.errors.BAD_STATE,
            "unsupported kind: " .. tostring(env.kind))
    end
end

make_handle = function(c)
    return {
        connect = function(_id) end,
        handshake = function(_id, header, _url)
            -- nginx 反代时带 x-real-ip，落库/审计用
            c.real_ip = header and header["x-real-ip"]
        end,
        message = function(_id, data, _op)
            stat.frames_in = stat.frames_in + 1
            local ok, env = pcall(message.decode, data)
            if not ok or type(env) ~= "table" then
                stat.bad_frames = stat.bad_frames + 1
                send_err(c, 0, 0, schema.errors.BAD_STATE, "bad json frame")
                return
            end
            -- 单帧内的异常不能冒泡到 accept 循环，否则整个连接被拆掉
            local ok2, err = pcall(handle_env, c, env)
            if not ok2 then
                stat.bad_frames = stat.bad_frames + 1
                skynet.error(string.format("[ws_gate] frame handler error fd=%d: %s",
                    c.fd, tostring(err)))
                send_err(c, env.seq, env.aid, schema.errors.BAD_STATE, "frame handler error")
            end
        end,
        ping = function(_id) end,
        pong = function(_id) end,
        close = function(id, _code, _reason) on_disconnect(id) end,
        error = function(id, _err) on_disconnect(id) end,
        warning = function(_ws, _sz) end,
    }
end

-- 每条连接一个协程：websocket.accept 内部是阻塞读循环，
-- skynet 里阻塞读只挂起本协程，不会卡住服务。
accept_one = function(fd, addr)
    local c = { fd = fd, addr = addr, alive = true, state = "handshake" }
    conns[fd] = c

    local ok, err = websocket.accept(fd, make_handle(c), "ws", addr)
    if not ok and err then
        skynet.error(string.format("[ws_gate] accept fd=%d failed: %s", fd, tostring(err)))
    end
    on_disconnect(fd)   -- 幂等：close 回调通常已经处理过
end

-- ========== 管理命令 ==========

function CMD.init(db_addr, login_addr, opts)
    db_svc, login_svc = db_addr, login_addr
    if opts and tonumber(opts.grace) and tonumber(opts.grace) > 0 then
        grace_ticks = math.floor(tonumber(opts.grace))
    end
    return true
end

function CMD.set_hub(hub_addr)
    hub_svc = hub_addr
    return true
end

function CMD.open(opts)
    opts = opts or {}
    local host = opts.address or "127.0.0.1"
    local port = tonumber(opts.port) or 9814
    listen_fd = socket.listen(host, port)
    socket.start(listen_fd, function(fd, addr)
        skynet.fork(accept_one, fd, addr)
    end)
    skynet.error(string.format("[ws_gate] listening ws://%s:%d (grace=%d)",
        host, port, grace_ticks))
    return port
end

function CMD.stats()
    local active, suspended = 0, 0
    for _, s in pairs(sessions) do
        if s.state == "active" then active = active + 1 else suspended = suspended + 1 end
    end
    return {
        online = online, active = active, suspended = suspended,
        total = active + suspended, conns = (function()
            local n = 0
            for _ in pairs(conns) do n = n + 1 end
            return n
        end)(),
        hello = stat.hello, frames_in = stat.frames_in, frames_out = stat.frames_out,
        bad_frames = stat.bad_frames, takeover = takeover,
        expire_count = #expire_log, grace = grace_ticks,
    }
end

-- 测试用：直接问某条连接现在绑的是哪个会话
function CMD.conn_of(fd)
    local c = conns[fd]
    if not c then return nil end
    return {
        fd = c.fd, state = c.state, alive = c.alive,
        uid = c.sess and c.sess.uid, token = c.sess and c.sess.token,
    }
end

function CMD.session_of(uid)
    local s = sessions[uid]
    if not s then return nil end
    return { uid = s.uid, account = s.account, token = s.token,
             state = s.state, fd = s.fd, gen = s.gen, agent = skynet.address(s.agent) }
end

function CMD.set_grace(n)
    n = tonumber(n)
    if n and n > 0 then grace_ticks = math.floor(n) end
    return grace_ticks
end

function CMD.last_expire()
    return expire_log[#expire_log]
end

-- 测试清场：丢弃索引与审计；在途 grace 回调因查不到会话自动失效
function CMD.reset_sessions(opts)
    for fd, c in pairs(conns) do
        c.alive = false
        -- 测试清场用静默关闭：发 WebSocket close 帧会写一个对端已消失的 fd，
        -- socket 层报 Broken pipe 后会把发起写入的服务打掉，给门禁制造噪音。
        if not websocket.is_close(fd) then pcall(socket.close, fd) end
    end
    conns, sessions, tokens = {}, {}, {}
    expire_log = {}
    online, takeover = 0, 0
    stat = { hello = 0, frames_in = 0, frames_out = 0, bad_frames = 0 }
    if opts and tonumber(opts.grace) and tonumber(opts.grace) > 0 then
        grace_ticks = math.floor(tonumber(opts.grace))
    end
    return true
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "ws_gate: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function() end)
