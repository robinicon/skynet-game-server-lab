-- gateway/gate.lua — Gate 服务（基于 snax.gateserver）
-- 依赖：proto/ + shared/
--
-- 职责：
--   1. TCP 监听与连接管理（fd ↔ uid ↔ agent）
--   2. 第一包 = 登录握手（sproto login_req），委托 login 服务认证
--   3. 后续包 = 业务消息，转发给该玩家的 agent 服务
--
-- 线上包格式：2 字节长度(不含自身) + payload + 4 字节 session
-- 下行包格式：2 字节长度(不含自身) + content + 1 字节 ok + 4 字节 session
--
-- 变更说明：旧版 gate 完全没有 socket（把 fd 当服务地址 skynet.call(session, ...)、
--           用 #agents 统计 hash 表长度恒为 0），现基于 gateserver 重写。

local skynet        = require "skynet"
local gateserver    = require "snax.gateserver"
local netpack       = require "skynet.netpack"
local socketdriver  = require "skynet.socketdriver"
local proto         = require "proto.proto"
local error_code    = require "shared.error_code"

local login_svc = nil

local handshake = {}   -- fd → addr（连接建立、尚未完成登录）
local logining  = {}   -- fd → true（登录处理中，期间丢弃业务包）
local connection = {}  -- fd → { uid, agent }
local online_conns = 0

local handler = {}

-- ========== 收发 ==========
local function send_response(fd, content, session)
    if not connection[fd] and not handshake[fd] and not logining[fd] then
        return
    end
    socketdriver.send(fd, netpack.pack(content .. string.pack(">BI4", 1, session)))
end

local function send_login_resp(fd, code, uid, token, reason, session)
    send_response(fd, proto.encode("login_resp", {
        code   = code,
        uid    = uid or 0,
        token  = token or "",
        reason = reason or "",
    }), session)
end

-- ========== 登录握手 ==========
local function do_login(fd, body, session)
    local addr = handshake[fd]
    handshake[fd] = nil
    logining[fd] = true

    local ok, req = pcall(proto.decode, "login_req", body)
    if not ok or type(req) ~= "table" then
        logining[fd] = nil
        send_login_resp(fd, error_code.ERR_INTERNAL, 0, "", "bad login_req", session)
        gateserver.closeclient(fd)
        return
    end

    local code, uid, token, reason
    local dbg = os.getenv("CH4_GATE_TIMING") == "1"
    local t0 = dbg and skynet.hpc() or 0
    if req.token and req.token ~= "" then
        code, uid, token, reason = skynet.call(login_svc, "lua", "login_by_token", req.token)
    else
        code, uid, token, reason = skynet.call(login_svc, "lua", "auth", req.uid, req.password)
    end
    local t1 = dbg and skynet.hpc() or 0

    if code ~= error_code.OK then
        logining[fd] = nil
        send_login_resp(fd, code, 0, "", reason, session)
        gateserver.closeclient(fd)
        return
    end

    local agent = skynet.call(login_svc, "lua", "login_handler", uid, token, fd)
    local t2 = dbg and skynet.hpc() or 0
    if dbg then
        skynet.error(string.format("[gate] timing: auth=%.2fms agent=%.2fms",
            (t1 - t0) / 1e6, (t2 - t1) / 1e6))
    end
    logining[fd] = nil

    if not agent then
        pcall(skynet.send, login_svc, "lua", "logout", uid)
        send_login_resp(fd, error_code.ERR_SERVICE_BUSY, 0, "", "agent alloc failed", session)
        gateserver.closeclient(fd)
        return
    end

    connection[fd] = { uid = uid, agent = agent }
    online_conns = online_conns + 1
    send_login_resp(fd, error_code.OK, uid, token, "", session)
    gateserver.openclient(fd)
end

-- ========== 业务消息 ==========
local function do_request(fd, body, session)
    local c = connection[fd]
    if not c then
        gateserver.closeclient(fd)
        return
    end
    local dt = os.getenv("CH4_GATE_TIMING") == "1" and skynet.hpc() or 0
    local ok, resp = pcall(skynet.call, c.agent, "lua", "client", body)
    if not ok then
        skynet.error(string.format("[gate] agent call failed: uid=%s err=%s", tostring(c.uid), tostring(resp)))
        resp = ""
    end
    send_response(fd, resp or "", session)
    if dt ~= 0 then
        skynet.error(string.format("[gate] timing: request=%.2fms", (skynet.hpc() - dt) / 1e6))
    end
end

-- ========== gateserver 回调 ==========
function handler.open(source, conf)
    skynet.error(string.format("[gate] listening on %s:%s (maxclient=%s)",
        tostring(conf.address), tostring(conf.port), tostring(conf.maxclient)))
end

function handler.connect(fd, addr)
    handshake[fd] = addr or ""
    -- 必须显式 openclient：gateserver 此时只是登记了连接，
    -- 不调用 socketdriver.start(fd) 就永远不会读取该 fd 上的数据
    gateserver.openclient(fd)
end

function handler.message(fd, msg, sz)
    local message = netpack.tostring(msg, sz)
    if #message < 4 then
        gateserver.closeclient(fd)
        return
    end
    local session = string.unpack(">I4", message, -4)
    local body    = message:sub(1, -5)

    if handshake[fd] then
        do_login(fd, body, session)
    elseif logining[fd] then
        -- 登录处理中（含 yield），期间的业务包直接丢弃
        return
    else
        do_request(fd, body, session)
    end
end

function handler.disconnect(fd)
    handshake[fd] = nil
    logining[fd]  = nil
    local c = connection[fd]
    if c then
        connection[fd] = nil
        online_conns = online_conns - 1
        -- agent 收到 afk 后会自行 logout 并退出
        pcall(skynet.send, c.agent, "lua", "afk")
    end
end

handler.error = handler.disconnect

function handler.warning(fd, size)
    skynet.error(string.format("[gate] fd=%d send buffer warning: %d bytes", fd, size))
end

-- ========== lua 命令（gateserver 的 CMD.open/close 之外的命令） ==========
function handler.command(cmd, source, ...)
    if cmd == "init" then
        login_svc = ...
        skynet.error(string.format("[gate] init: login=%s", tostring(login_svc)))
        return true
    elseif cmd == "online_count" then
        return online_conns
    elseif cmd == "kick" then
        local uid = ...
        for fd, c in pairs(connection) do
            if c.uid == uid then
                gateserver.closeclient(fd)
            end
        end
        return true
    end
    skynet.error(string.format("[gate] unknown cmd: %s", tostring(cmd)))
    return nil
end

gateserver.start(handler)
