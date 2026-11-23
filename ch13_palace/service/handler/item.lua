-- service/handler/item.lua — 背包/道具批次
--
-- 迁移自 palace-game: ItemService（useProp / itemSale）。
-- 道具定义（类型、效果值、出售价、堆叠）来自 conf/gamedata.xlsx 的 item 表。
-- 语义约定：
--   kind=gold / silver —— 使用后直接加对应货币
--   kind=elixir        —— 只能由英雄升级吞掉，不可直接使用（与原工程一致）
--   kind=material      —— 无使用效果
--   sellPrice=0        —— 原 sellType=0，不可出售

local gd     = require "shared.gamedata"
local baglib = require "shared.bag"
local schema = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

local function norm_id(raw)
    local n = tonumber(raw)
    return n and math.floor(n) or nil
end

-- u.useItem(itemId, useCount, index)
function M.use(ctx, params)
    local itemId = norm_id(params.itemId)
    if not itemId then return fail("bad_item_id") end
    local item = gd.item(itemId)
    if not item then return fail("item_not_found", { itemId = itemId }) end

    local count = tonumber(params.useCount) or 1
    count = math.floor(count)
    if count < 1 then return fail("bad_count", { useCount = params.useCount }) end

    local cur_bag = ctx.get("bag") or {}
    local have = baglib.count(cur_bag, itemId)
    if have < count then
        return fail("item_not_enough", { itemId = itemId, have = have, need = count })
    end

    local changes, result = {}, { ok = true, itemId = itemId, useCount = count }

    if item.kind == "gold" or item.kind == "silver" then
        local add = item.value * count
        local field = item.kind
        local cur = ctx.get(field) or 0
        changes[field] = cur + add
        result.gain = add
        result.field = field
    elseif item.kind == "elixir" then
        -- 经验丹走英雄升级消耗，不提供直接使用
        return fail("not_usable", { itemId = itemId, kind = item.kind })
    else
        return fail("not_usable", { itemId = itemId, kind = item.kind })
    end

    local new_bag = baglib.set(cur_bag, itemId, have - count)
    changes.bag = new_bag
    return { err = E.OK, changes = changes, result = result }
end

-- u.itemSale(itemId, count)
function M.sale(ctx, params)
    local itemId = norm_id(params.itemId)
    if not itemId then return fail("bad_item_id") end
    local item = gd.item(itemId)
    if not item then return fail("item_not_found", { itemId = itemId }) end

    local count = math.floor(tonumber(params.count) or 1)
    if count < 1 then return fail("bad_count", { count = params.count }) end

    -- 原实现先判数量，再判是否可售
    local cur_bag = ctx.get("bag") or {}
    local have = baglib.count(cur_bag, itemId)
    if have < count then
        return fail("item_not_enough", { itemId = itemId, have = have, need = count })
    end
    if item.sellPrice <= 0 then return fail("not_sellable", { itemId = itemId }) end

    local gain = item.sellPrice * count
    local silver = (ctx.get("silver") or 0) + gain
    local new_bag = baglib.set(cur_bag, itemId, have - count)

    return {
        err = E.OK,
        changes = { bag = new_bag, silver = silver },
        result = { ok = true, itemId = itemId, count = count, silver = silver, gain = gain },
    }
end

local BY_OP = {
    ["u.useItem"]  = M.use,
    ["u.itemSale"] = M.sale,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "item: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
