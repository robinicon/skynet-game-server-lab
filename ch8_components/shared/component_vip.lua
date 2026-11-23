-- shared/component_vip.lua — VIP 组件（用于演示**运行时动态注入**）
--
-- 与 bag/skill/quest 不同，它不在 Agent 启动时加载，
-- 而是在运行期由外部命令注入 —— 验证"不重启 Agent 即可添加组件"。

local error_code = require "shared.error_code"

local M = {}

M.name = "vip"

function M.init(ctx)
    ctx.vip = { level = 0, injected_at = ctx.now or 0 }
    return true
end

function M.shutdown(ctx)
    ctx.vip = nil
    return true
end

M.handlers = {}

M.handlers["vip.set"] = function(ctx, level)
    if not ctx.vip then
        return error_code.ERR_INVALID_ARG, "vip not initialized"
    end
    ctx.vip.level = tonumber(level) or 0
    return error_code.OK, ctx.vip.level
end

M.handlers["vip.info"] = function(ctx)
    return error_code.OK, ctx.vip
end

return M
