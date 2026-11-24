-- shared/gm_double.lua — GM 命令示例：把 n 翻倍
--
-- GM 命令以模块形式提供（导出 run(args) -> result），
-- 由 http_mgr 在服务端内部 require —— 模块可热更替换。

local M = {}

function M.run(args)
    local n = tonumber(args.n)
    if not n then
        return { error = "missing numeric arg 'n'" }
    end
    return { result = n * 2 }
end

return M
