-- shared/error_code.lua — 统一错误码枚举
-- 所有服务层函数返回此模块中的错误码，避免魔法数字
--
-- 命名规范：ERROR_<模块>_<描述>
-- 值约定：
--   0        = 成功
--   正整数   = 业务错误（网关可映射为 HTTP/WS 状态码）
--   负整数   = 系统/网络错误

local M = {}

-- 登录模块
M.OK                     =  0
M.ERR_UNKNOWN_ACCOUNT    =  1
M.ERR_WRONG_PASSWORD     =  2
M.ERR_ALREADY_LOGGED_IN  =  3
M.ERR_TOKEN_EXPIRED      =  4
M.ERR_INVALID_TOKEN      =  5
M.ERR_LOGIN_QUEUE_FULL   =  6
M.ERR_SERVICE_BUSY       =  7
M.ERR_NOT_ONLINE         =  8   -- Token 有效但账号已不在线（已登出）

-- 通用错误
M.ERR_INTERNAL           = -1
M.ERR_NETWORK            = -2
M.ERR_TIMEOUT            = -3

-- 错误码 → 可读描述（用于日志和压测报告）
local CODE_DESC = {}
for k, v in pairs(M) do
    if type(v) == "number" then
        CODE_DESC[v] = k
    end
end

function M.desc(code)
    return CODE_DESC[code] or string.format("UNKNOWN(%d)", code)
end

return M
