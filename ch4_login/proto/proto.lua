-- proto/proto.lua — sproto 协议编译与加载
-- 依赖：仅 skynet（sproto/sprotoparser 位于 skynet/lualib）
--
-- game.proto 为 sproto 源码格式（非 protobuf），
-- 使用 sproto.parse() 解析文本得到实例，再用 encode/decode 收发。

local skynet = require "skynet"

local M = {}

local PROTO_SOURCE = "proto/game.proto"
local _sproto = nil

--- 初始化协议（启动时调用一次，幂等）
function M.init()
    if _sproto then
        return _sproto
    end

    local sproto_mod = require "sproto"   -- ../skynet/lualib/sproto.lua
    local f = assert(io.open(PROTO_SOURCE, "r"), "proto source not found: " .. PROTO_SOURCE)
    local source = f:read("*a")
    f:close()

    _sproto = sproto_mod.parse(source)    -- 解析 sproto 文本（内部走 sprotoparser）
    skynet.error(string.format("[proto] loaded %s", PROTO_SOURCE))
    return _sproto
end

--- 获取 sproto 实例（未初始化时自动初始化）
function M.get()
    return _sproto or M.init()
end

--- 编码消息
-- @param typename  消息类型名（如 "login_resp"）
-- @param tbl       消息表
-- @return packed binary string
function M.encode(typename, tbl)
    return M.get():encode(typename, tbl)
end

--- 解码消息
-- @param typename  消息类型名
-- @param data      二进制数据
-- @return table
function M.decode(typename, data)
    return M.get():decode(typename, data)
end

--- 打包 login_resp（便捷封装）
function M.pack_login_resp(code, uid, token, reason)
    return M.encode("login_resp", {
        code   = code,
        uid    = uid,
        token  = token,
        reason = reason,
    })
end

--- 解包 login_resp（便捷封装）
function M.unpack_login_resp(data)
    return M.decode("login_resp", data)
end

return M
