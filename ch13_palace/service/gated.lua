-- service/gated.lua — TCP 网关 + legacy JSON 协议 + 会话状态机
--
-- 帧格式（与 ch4_login/gateway/gated.lua 一致，现有客户端零改动）：
--   上行/下行：2 字节长度(不含自身) + JSON + 4 字节 session
-- JSON 信封：{ id, type, scope, op, error, params }
--
-- 职责：
--   1. 首包必须是 u.login / u.create（aid=1/2），鉴权后加载或创建实体、绑定 agent
--   2. 后续包：legacy → 统一信封 → agent.dispatch → legacy 回包
--   3. 未知 op 回 UNKNOWN_OP(-100)，不关闭连接；首包非法才关闭
--   4. 会话状态机（阶段 3）：
--        active    —— fd 在线，连接表绑定
--        suspended —— 断线挂起，agent 保留，等待 grace 窗口内重连
--        顶号      —— 同 uid 新登录先摘除旧 fd，旧连接随后 disconnect 不会误伤新会话
--        超时      —— grace 到期调用 agent.expire 落盘，再 shutdown
--      全部状态都在本服务内，skynet 单服务串行天然无锁。
--
-- 注意：服务名必须是 gated，不能叫 gate —— skynet 内置服务里有同名 gate。

local skynet       = require "skynet"
local gateserver   = require "snax.gateserver"
local netpack      = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"
local message      = require "shared.message"
local schema       = require "shared.schema"

local db_svc, login_svc
local hub_svc            -- P0.5：跨服中心地址，由 main 注入；建 agent 时透传

local handshake  = {}  -- fd → addr（已连接，尚未鉴权）
local logining   = {}  -- fd → true（鉴权中，期间丢弃业务包）
local connection = {}  -- fd → { uid, agent, account, token, sess }
local online_conns = 0

-- 阶段 3：会话索引
local session_by_uid   = {}  -- entity uid → session
local session_by_token = {}  -- token → session（优先精确找回）
local expire_log       = {}  -- 超时落盘审计
local grace_ticks      = 300 -- 3 秒（skynet.timeout 单位 0.01s），配置可覆盖
local takeover_count    = 0  -- 顶号次数（测试与监控用）

local handler = {}

-- ========== 收发 ==========

local function send_wire(fd, text, session)
    if not handshake[fd] and not logining[fd] and not connection[fd] then return end
    local ok, err = pcall(socketdriver.send, fd,
        netpack.pack(text .. string.pack(">I4", session)))
    if not ok then
        skynet.error(string.format("[gated] send failed fd=%d err=%s", fd, tostring(err)))
    end
end

local function send_legacy(fd, legacy, session)
    local ok, text = pcall(message.encode, legacy)
    if not ok then
        skynet.error("[gated] encode failed: " .. tostring(text))
        return
    end
    send_wire(fd, text, session)
end

local function send_envelope(fd, envelope, session)
    local legacy = message.to_legacy(envelope)
    if not legacy then
        legacy = {
            id = session, type = "r", scope = "c", op = "u.error",
            error = schema.errors.BAD_STATE,
            params = { ok = false, reason = "unsupported envelope" },
        }
    end
    send_legacy(fd, legacy, session)
end

local function reply_error(fd, session, op, code, reason)
    send_legacy(fd, {
        id = session, type = "r", scope = "c", op = op or "u.error",
        error = code, params = { ok = false, reason = reason or "" },
    }, session)
end

-- ========== 会话生命周期 ==========

local function arm_grace(s)
    s.gen = s.gen + 1
    local uid, gen = s.uid, s.gen
    skynet.timeout(grace_ticks, function()
        local cur = session_by_uid[uid]
        -- gen 或对象不一致说明已重连/已重建，旧定时器自然失效
        if not cur or cur ~= s or cur.gen ~= gen or cur.state ~= "suspended" then return end

        local ok, res = pcall(skynet.call, s.agent, "lua", "expire")
        if ok and type(res) == "table" then
            expire_log[#expire_log + 1] = {
                uid = uid, token = s.token, at = skynet.time(),
                written = res.written or {}, ok = res.ok,
            }
        else
            skynet.error(string.format("[gated] expire failed uid=%d err=%s",
                uid, tostring(res)))
        end

        session_by_uid[uid] = nil
        if s.token then session_by_token[s.token] = nil end
        pcall(skynet.send, s.agent, "lua", "shutdown")
    end)
end

local function send_login_result(fd, sid, op, s, snap, addr)
    -- 登录回包：保持老协议 op，客户端零改动（只回一帧，随后一帧快照）
    send_legacy(fd, {
        id = sid, type = "r", scope = "c", op = op,
        error = schema.errors.OK,
        params = { ok = true, uid = s.uid, token = s.token, addr = addr or "" },
    }, sid)

    -- 初始快照：统一 SNAPSHOT 信封由 message 层转回 u.snapshot
    -- agent 内部 seq=0，过线前由网关对齐本次请求的 session
    if snap then
        snap.seq = sid
        send_envelope(fd, snap, sid)
    end
    gateserver.openclient(fd)
end

-- ========== 首包登录 ==========

local function do_login(fd, legacy, session)
    local addr = handshake[fd]
    handshake[fd] = nil
    logining[fd] = true

    -- 阶段 4：信封级 capability 协商。老客户端不带 legacy.wire，默认 1（全量兼容）；
    -- 新客户端带 wire=2，启用策略过滤快照 + 独立 u.delta 包 + 分区订阅。
    local want_wire = (tonumber(legacy.wire) == 2) and 2 or 1

    local env, err = message.normalize_in(legacy)
    local action = env and schema.action(env.aid)
    if not env or not action or (env.aid ~= 1 and env.aid ~= 2) then
        -- 先回错误帧再清登录态：send_wire 的存活守卫依赖 handshake/logining/connection
        reply_error(fd, session, legacy.op, schema.errors.UNKNOWN_OP,
            err or "first packet must be u.login or u.create")
        logining[fd] = nil
        gateserver.closeclient(fd)
        return
    end

    local account = env.params.account
    local password = env.params.password
    local want_token = env.params.token  -- 阶段 3：schema 里 u.login 第三位，可为空
    if not account or not password then
        reply_error(fd, session, legacy.op, schema.errors.BAD_ACCOUNT, "account/password required")
        logining[fd] = nil
        gateserver.closeclient(fd)
        return
    end

    local code, uid, token
    if env.aid == 2 then  -- u.create：幂等，已存在则直接进入认证
        local c = skynet.call(login_svc, "lua", "create_account", account, password)
        if c == schema.errors.OK or c == schema.errors.EXISTS then
            code, uid, token = skynet.call(login_svc, "lua", "auth", account, password)
        else
            code, uid, token = c, 0, ""
        end
    else
        code, uid, token = skynet.call(login_svc, "lua", "auth", account, password)
    end

    if code ~= schema.errors.OK then
        reply_error(fd, session, legacy.op, code, "authentication failed")
        logining[fd] = nil
        gateserver.closeclient(fd)
        return
    end

    -- 找回会话：带 token 则精确匹配（且 uid 一致），否则按 uid 兜底
    local s
    if want_token and want_token ~= "" then
        local by_token = session_by_token[want_token]
        if by_token and by_token.uid == uid then s = by_token end
    end
    if not s then s = session_by_uid[uid] end

    local snap
    if s then
        -- 顶号：旧 active fd 先收到通知帧，再摘除连接；其后的 disconnect 不会误伤新会话
        if s.state == "active" and s.fd and connection[s.fd] then
            local oldfd = s.fd
            reply_error(oldfd, 0, "u.error", schema.errors.BAD_STATE, "kicked by new login")
            connection[oldfd] = nil
            online_conns = math.max(0, online_conns - 1)
            takeover_count = takeover_count + 1
            gateserver.closeclient(oldfd)
        end

        -- 恢复：gen 自增使旧 grace 回调失效；agent.resume 返回当前快照
        s.gen = s.gen + 1
        s.state = "active"
        s.fd = fd
        if s.token ~= token and s.token then session_by_token[s.token] = nil end
        s.token = s.token or token
        session_by_token[s.token] = s
        session_by_uid[s.uid] = s

        skynet.call(s.agent, "lua", "set_wire", want_wire)
        local okr, snap_or_err = pcall(skynet.call, s.agent, "lua", "resume", fd)
        if okr then
            snap = snap_or_err
        else
            -- agent 已退出（例如超时竞态）：清掉旧会话，走新建
            skynet.error(string.format("[gated] resume failed uid=%d err=%s",
                s.uid, tostring(snap_or_err)))
            session_by_uid[s.uid] = nil
            if s.token then session_by_token[s.token] = nil end
            s = nil
        end
    end

    if not s then
        local euid = skynet.call(db_svc, "lua", "find_entity_by_account", account)
        if not euid then
            euid = skynet.call(db_svc, "lua", "create_entity", "avatar", 0, account, uid)
        end
        local agent = skynet.newservice("agent")
        skynet.call(agent, "lua", "init", db_svc, euid)
        if hub_svc then skynet.call(agent, "lua", "set_hub", hub_svc) end
        skynet.call(agent, "lua", "set_wire", want_wire)
        s = {
            uid = euid, account = account, agent = agent, token = token,
            state = "active", fd = fd, gen = 0, wire = want_wire,
        }
        session_by_uid[euid] = s
        session_by_token[token] = s
    end

    logining[fd] = nil
    connection[fd] = {
        uid = s.uid, agent = s.agent, account = s.account,
        token = s.token, sess = s,
    }
    online_conns = online_conns + 1

    if not snap then snap = skynet.call(s.agent, "lua", "snapshot") end
    send_login_result(fd, session, legacy.op, s, snap, addr)
end

-- ========== 业务消息 ==========

local function do_request(fd, legacy, session)
    local c = connection[fd]
    if not c then
        gateserver.closeclient(fd)
        return
    end

    local env, err = message.normalize_in(legacy)
    if not env then
        reply_error(fd, session, legacy.op, schema.errors.UNKNOWN_OP,
            err or "unknown op")
        return
    end

    local ok, resp = pcall(skynet.call, c.agent, "lua", "dispatch", env)
    if not ok or type(resp) ~= "table" then
        reply_error(fd, session, legacy.op, schema.errors.BAD_STATE,
            "agent dispatch failed: " .. tostring(resp))
        return
    end

    local out = message.to_legacy(resp)
    if not out then
        reply_error(fd, session, legacy.op, schema.errors.BAD_STATE, "cannot convert response")
        return
    end

    -- 阶段 4：wire=1（legacy）把 delta 嵌入回包 params，老客户端零改动；
    -- wire=2 则 delta 作为独立 u.delta 包下发（客户端按 base_rev 校验后应用）。
    local is_wire2 = (c.sess and c.sess.wire or 1) >= 2
    if resp.delta and not is_wire2 then
        out.params.delta = resp.delta
    end
    send_legacy(fd, out, session)

    if is_wire2 and resp.delta then
        local d = resp.delta
        d.seq = session
        send_envelope(fd, d, session)  -- 独立 u.delta 帧
    end
end

-- ========== gateserver 回调 ==========

function handler.connect(fd, addr)
    handshake[fd] = addr or ""
    -- gateserver 只登记连接；必须显式 openclient 才会读取该 fd 上的数据
    gateserver.openclient(fd)
end

function handler.message(fd, msg, sz)
    local wire = netpack.tostring(msg, sz)
    if #wire < 4 then
        gateserver.closeclient(fd)
        return
    end

    local session = string.unpack(">I4", wire, -4)
    local text = wire:sub(1, -5)
    local legacy = message.decode(text)

    if type(legacy) ~= "table" then
        reply_error(fd, session, "u.error", schema.errors.BAD_STATE, "bad JSON envelope")
        if handshake[fd] then gateserver.closeclient(fd) end
        return
    end

    if handshake[fd] then
        do_login(fd, legacy, session)
    elseif logining[fd] then
        -- 鉴权期间（含 skynet.call yield）到达的业务包直接丢弃
        return
    else
        do_request(fd, legacy, session)
    end
end

function handler.disconnect(fd)
    handshake[fd] = nil
    logining[fd] = nil
    local c = connection[fd]
    if not c then return end
    connection[fd] = nil
    online_conns = math.max(0, online_conns - 1)

    local s = c.sess
    -- 顶号时旧 fd 已被摘除（s.fd 指向新连接），它的 disconnect 不得挂起新会话
    if not s or s.fd ~= fd or s.state ~= "active" then return end

    s.fd = nil
    s.state = "suspended"
    pcall(skynet.call, s.agent, "lua", "suspend")
    arm_grace(s)
end

handler.error = handler.disconnect

function handler.warning(fd, size)
    skynet.error(string.format("[gated] fd=%d send buffer warning: %d bytes", fd, size))
end

-- ========== 管理命令 ==========

function handler.command(cmd, source, ...)
    if cmd == "init" then
        local opts
        db_svc, login_svc, opts = ...
        if opts and tonumber(opts.grace) and tonumber(opts.grace) > 0 then
            grace_ticks = math.floor(tonumber(opts.grace))
        end
        skynet.error(string.format("[gated] init db=%s login=%s grace=%d",
            tostring(db_svc), tostring(login_svc), grace_ticks))
        return true
    elseif cmd == "online_count" then
        return online_conns
    elseif cmd == "kick" then
        local uid = ...
        for fd, c in pairs(connection) do
            if c.uid == uid then gateserver.closeclient(fd) end
        end
        return true
    elseif cmd == "set_grace" then
        local n = tonumber(...)
        if n and n > 0 then grace_ticks = math.floor(n) end
        return grace_ticks
    elseif cmd == "set_hub" then
        hub_svc = ...
        return true
    elseif cmd == "reset_sessions" then
        -- 仅供测试清场：丢弃所有会话索引与审计；在途 grace 回调因查不到会话自动失效
        session_by_uid = {}
        session_by_token = {}
        expire_log = {}
        takeover_count = 0
        return true
    elseif cmd == "session_stats" then
        local active, suspended = 0, 0
        for _, s in pairs(session_by_uid) do
            if s.state == "active" then active = active + 1 else suspended = suspended + 1 end
        end
        return {
            active = active, suspended = suspended, total = active + suspended,
            expire_count = #expire_log, takeover = takeover_count, grace = grace_ticks,
        }
    elseif cmd == "session_of" then
        local uid = ...
        local s = session_by_uid[uid]
        if not s then return nil end
        return {
            uid = s.uid, account = s.account, token = s.token,
            state = s.state, fd = s.fd, agent = skynet.address(s.agent), gen = s.gen,
        }
    elseif cmd == "last_expire" then
        return expire_log[#expire_log]
    end
    skynet.error("[gated] unknown command: " .. tostring(cmd))
    return nil
end

gateserver.start(handler)
