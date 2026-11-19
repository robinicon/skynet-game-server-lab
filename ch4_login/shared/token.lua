-- shared/token.lua — Token 生成与校验策略
--
-- 设计变更（相对旧实现）：
--   旧：token = "uid|timestamp:md5(md5(secret..raw)..raw)"
--       - 每次登录 2 次 MD5 + 2 次字符串拼接
--       - 明文内嵌 uid 与时间戳，可被解析/伪造时间戳
--   新：token = base64(randomkey() .. randomkey())   128bit 随机串
--       - 零哈希开销，一次随机数生成
--       - 不携带任何可读信息，无法伪造
--       - 归属与有效期由 center 侧的 token_index 维护（查表 O(1)）
--
-- 依赖：skynet.crypt（由 skynet.so 提供 randomkey / base64encode）

local skynet = require "skynet"
local crypt  = require "skynet.crypt"

local M = {}

M.TTL = 7200  -- 秒，实际生效时间在 center 侧

--- 生成新 Token（128bit 随机串，base64 后 24 字符）
-- @return token string
function M.generate()
    return crypt.base64encode(crypt.randomkey() .. crypt.randomkey())
end

--- 格式校验（字符集与长度，不含归属/有效期判断）
-- @return boolean
function M.wellformed(token)
    if type(token) ~= "string" then
        return false
    end
    if #token < 16 or #token > 64 then
        return false
    end
    return token:find("[^A-Za-z0-9%+/=]") == nil
end

--- 是否过期
function M.expired(expire_at, now)
    return (now or skynet.time()) > expire_at
end

return M
