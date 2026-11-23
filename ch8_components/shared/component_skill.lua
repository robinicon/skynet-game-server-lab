-- shared/component_skill.lua — 技能组件

local error_code = require "shared.error_code"

local M = {}

M.name = "skill"

function M.init(ctx)
    ctx.skill = { list = {}, cast_count = 0 }
    return true
end

function M.shutdown(ctx)
    ctx.skill_last_cast = ctx.skill and ctx.skill.cast_count or 0
    ctx.skill = nil
    return true
end

M.handlers = {}

--- 学习技能（消耗背包道具：跨组件通信示例）
-- 注意：不 require component_bag，而是通过 ctx.core:dispatch 走路由。
-- 这样两个组件之间**没有编译期依赖**，可以独立替换/热更。
M.handlers["skill.learn"] = function(ctx, skill_id)
    local bag = ctx.bag
    if not bag then
        return error_code.ERR_INVALID_ARG, "bag component missing"
    end
    -- 需要 1 个"技能书"（item_id = 1001）
    if (bag.items[1001] or 0) < 1 then
        return error_code.ERR_INVALID_ARG, "no skill book"
    end
    if not ctx.core then
        return error_code.ERR_INTERNAL, "core not available"
    end
    local code = ctx.core:dispatch("bag.remove", 1001, 1)
    if code ~= error_code.OK then
        return code, "consume failed"
    end
    ctx.skill.list[skill_id] = { level = 1 }
    return error_code.OK, ctx.skill.list[skill_id]
end

--- 施放技能
M.handlers["skill.cast"] = function(ctx, skill_id)
    local s = ctx.skill and ctx.skill.list[skill_id]
    if not s then
        return error_code.ERR_INVALID_ARG, "skill not learned"
    end
    ctx.skill.cast_count = ctx.skill.cast_count + 1
    return error_code.OK, { skill_id = skill_id, level = s.level, cast = ctx.skill.cast_count }
end

--- 查询
M.handlers["skill.list"] = function(ctx)
    return error_code.OK, ctx.skill and ctx.skill.list or {}
end

return M
