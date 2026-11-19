-- test/robot.lua — TCP 机器人客户端（供 stress_e2e 使用）
--
-- 复用 gate 的线上包格式：
--   上行：2 字节长度(不含自身) + payload + 4 字节 session
--   下行：2 字节长度(不含自身) + content + 1 字节 ok + 4 字节 session
--
-- 依赖 skynet.socket（阻塞 API，必须在协程内调用）

local socket       = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"
local proto        = require "proto.proto"

local M = {}

--- 组装上行包
function M.pack(payload, session)
    return string.pack(">s2", payload .. string.pack(">I4", session or 0))
end

--- 拆解下行包 → content, ok_byte, session
function M.unpack(body)
    if not body or #body < 5 then
        return nil, nil, nil
    end
    local content = body:sub(1, -6)
    local ok_byte = string.byte(body, -5)
    local session = string.unpack(">I4", body, -4)
    return content, ok_byte, session
end

--- 读取一个完整下行包
function M.read_pack(fd)
    local head = socket.read(fd, 2)
    if not head or #head < 2 then
        return nil
    end
    local n = string.unpack(">I2", head)
    if n <= 0 then
        return nil
    end
    return socket.read(fd, n)
end

--- 建立连接（socket.open 内部 suspend 等待连接结果，返回 fd 或 nil, err）
-- 必须开启 nodelay：否则小包会被 Nagle 算法与延迟 ACK 拖到 40ms 量级，
-- 一次登录请求往返就是 80ms+（实测 85ms）
function M.connect(addr, port)
    local fd = socket.open(addr, port)
    if fd then
        socketdriver.nodelay(fd)
    end
    return fd
end

--- 登录握手
-- @return resp table | nil, err
function M.login(fd, username, password, token)
    local req = proto.encode("login_req", {
        uid      = username or "",
        password = password or "",
        token    = token or "",
    })
    socket.write(fd, M.pack(req, 1))
    local body = M.read_pack(fd)
    if not body then
        return nil, "no response"
    end
    local content = M.unpack(body)
    if not content then
        return nil, "bad response"
    end
    local ok, resp = pcall(proto.decode, "login_resp", content)
    if not ok then
        return nil, "decode failed"
    end
    return resp
end

--- 业务请求（cmd + sproto payload）
function M.request(fd, cmd_byte, payload, session)
    socket.write(fd, M.pack(string.char(cmd_byte) .. payload, session or 2))
    return M.read_pack(fd)
end

function M.close(fd)
    socket.close(fd)
end

return M
