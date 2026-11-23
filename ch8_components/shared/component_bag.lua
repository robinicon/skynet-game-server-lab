-- shared/component_bag.lua — 背包组件
--
-- 组件契约：
--   init(ctx)      映射 IAwakeSystem，Agent 启动时调用
--   shutdown(ctx)  Agent 销毁时调用（逆序）
--   handlers       { ["bag.xxx"] = function(ctx, ...) -> code, ... }
--
-- 组件之间**不互相 require**：跨组件通信走 ctx（共享上下文）或 ctx.core:dispatch()

local error_code = require "shared.error_code"

local M = {}

M.name = "bag"

function M.init(ctx)
    ctx.bag = { items = {}, capacity = tonumber(ctx.bag_capacity) or 20 }
    return true
end

function M.shutdown(ctx)
    -- 真实项目里这里通常是"把背包数据交还 DB 服务存盘"
    ctx.bag_last_snapshot = ctx.bag and #ctx.bag.items or 0
    ctx.bag = nil
    return true
end

M.handlers = {}

--- 加道具
M.handlers["bag.add"] = function(ctx, item_id, count)
    count = tonumber(count) or 1
    local bag = ctx.bag
    if not bag then
        return error_code.ERR_INVALID_ARG, "bag not initialized"
    end
    if #bag.items >= bag.capacity then
        return error_code.ERR_INVALID_ARG, "bag full"
    end
    bag.items[item_id] = (bag.items[item_id] or 0) + count
    return error_code.OK, bag.items[item_id]
end

--- 扣道具
M.handlers["bag.remove"] = function(ctx, item_id, count)
    count = tonumber(count) or 1
    local bag = ctx.bag
    if not bag then
        return error_code.ERR_INVALID_ARG, "bag not initialized"
    end
    local have = bag.items[item_id] or 0
    if have < count then
        return error_code.ERR_INVALID_ARG, "not enough items"
    end
    bag.items[item_id] = have - count
    if bag.items[item_id] == 0 then
        bag.items[item_id] = nil
    end
    return error_code.OK, bag.items[item_id] or 0
end

--- 查询
M.handlers["bag.list"] = function(ctx)
    local bag = ctx.bag
    if not bag then
        return error_code.ERR_INVALID_ARG, nil
    end
    local n = 0
    for _ in pairs(bag.items) do n = n + 1 end
    return error_code.OK, { items = bag.items, kinds = n, capacity = bag.capacity }
end

return M
