-- service/handler/view.lua — 纯读类动作
--
-- 只返回当前 rev 与核心展示字段，不产生 changes（因此不会推 delta）。

local schema = require "shared.schema"

local M = {}

function M.handle(ctx, action)
    local op = action and action.op or ""
    if op == "u.avatar_info" then
        return {
            err = schema.errors.OK,
            result = {
                ok = true,
                rev = ctx.rev,
                account = ctx.get("account"),
                level = ctx.get("level"),
                gold = ctx.get("gold"),
                silver = ctx.get("silver"),
                vip = ctx.get("vip"),
                zhanli = ctx.get("zhanli"),
            },
        }
    end
    return { err = schema.errors.UNKNOWN_OP, result = { ok = false, reason = "view: unknown op " .. tostring(op) } }
end

return M
