-- test/gateclient.lua — 测试用 TCP 客户端（与 gated.lua 共帧格式）
--
-- 依赖 skynet.socket 的阻塞 API，必须在协程（测试服务）内调用。
-- 帧：2 字节大端长度(不含自身) + payload + 4 字节大端 session

local socket       = require "skynet.socket"
local socketdriver = require "skynet.socketdriver"
local message      = require "shared.message"

local M = {}

function M.pack(text, session)
    return string.pack(">s2", text .. string.pack(">I4", session or 0))
end

function M.unpack(wire)
    if type(wire) ~= "string" or #wire < 4 then return nil, nil end
    return wire:sub(1, -5), string.unpack(">I4", wire, -4)
end

function M.read_pack(fd)
    local head = socket.read(fd, 2)
    if not head or #head < 2 then return nil end
    local n = string.unpack(">I2", head)
    if n <= 0 then return nil end
    return M.unpack(socket.read(fd, n))
end

function M.connect(addr, port)
    local fd = socket.open(addr, port)
    if fd then socketdriver.nodelay(fd) end
    return fd
end

function M.send(fd, legacy, session)
    local text = message.encode(legacy)
    return socket.write(fd, M.pack(text, session))
end

function M.request(fd, legacy, session)
    M.send(fd, legacy, session)
    local text, sid = M.read_pack(fd)
    if not text then return nil, sid end
    return message.decode(text), sid
end

function M.close(fd)
    if fd then socket.close(fd) end
end

return M
