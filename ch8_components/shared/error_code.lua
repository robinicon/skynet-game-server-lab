-- shared/error_code.lua — 统一错误码枚举（与 ch4_login 保持一致）

local M = {}

M.OK                     =  0
M.ERR_INVALID_ARG        =  1
M.ERR_POOL_FULL          =  2
M.ERR_FOREIGN_OBJECT     =  3
M.ERR_DOUBLE_FREE        =  4
M.ERR_RESET_FAILED       =  5
M.ERR_NOT_FOUND          =  6

M.ERR_INTERNAL           = -1

local CODE_DESC = {}
for k, v in pairs(M) do
    if type(v) == "number" then
        CODE_DESC[v] = k
    end
end

function M.desc(code)
    return CODE_DESC[code] or string.format("UNKNOWN(%d)", tostring(code))
end

return M
