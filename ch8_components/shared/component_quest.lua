-- shared/component_quest.lua — 任务组件

local error_code = require "shared.error_code"

local M = {}

M.name = "quest"

function M.init(ctx)
    ctx.quest = { active = {}, done = {} }
    return true
end

function M.shutdown(ctx)
    ctx.quest_last_done = (function()
        local n = 0
        if ctx.quest then for _ in pairs(ctx.quest.done) do n = n + 1 end end
        return n
    end)()
    ctx.quest = nil
    return true
end

M.handlers = {}

M.handlers["quest.accept"] = function(ctx, quest_id)
    ctx.quest.active[quest_id] = { progress = 0 }
    return error_code.OK, ctx.quest.active[quest_id]
end

--- 推进进度
M.handlers["quest.progress"] = function(ctx, quest_id, delta)
    local q = ctx.quest.active[quest_id]
    if not q then
        return error_code.ERR_INVALID_ARG, "quest not active"
    end
    q.progress = q.progress + (tonumber(delta) or 1)
    if q.progress >= 10 then
        return M.handlers["quest.complete"](ctx, quest_id)
    end
    return error_code.OK, q
end

--- 完成任务 → 发奖励（跨组件通信：通过 core 路由给 bag 加道具）
M.handlers["quest.complete"] = function(ctx, quest_id)
    local q = ctx.quest.active[quest_id]
    if not q then
        return error_code.ERR_INVALID_ARG, "quest not active"
    end
    ctx.quest.active[quest_id] = nil
    ctx.quest.done[quest_id] = true

    -- 奖励：走 core 路由，不直接依赖 bag 组件
    local reward_id, reward_count = 2001, 5
    if ctx.core then
        ctx.core:dispatch("bag.add", reward_id, reward_count)
    end
    return error_code.OK, { quest_id = quest_id, reward = reward_id, count = reward_count }
end

M.handlers["quest.list"] = function(ctx)
    return error_code.OK, { active = ctx.quest.active, done = ctx.quest.done }
end

return M
