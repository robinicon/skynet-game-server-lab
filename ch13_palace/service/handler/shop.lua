-- service/handler/shop.lua — 商店批次（U4）
--
-- 表驱动：货品/价格/限购来自 conf/gamedata.xlsx 的 shop 表。
-- 已购数存 activity.shop.bought（不新增 schema field）。
-- 货币扣加复用 bag/字段语义：gold/silver 直接改字段，其余进背包。

local gd       = require "shared.gamedata"
local progress = require "shared.progress"
local baglib   = require "shared.bag"
local schema   = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

-- u.shopList() — 只读货品列表（含已购数）
function M.list(ctx, params)
    local activity = ctx.get("activity") or {}
    local shop_sec = progress.section(activity, "shop")
    local bought = shop_sec.bought or {}
    local goods = {}
    for _, g in pairs(gd.raw.shop) do
        goods[#goods + 1] = {
            goodsId = g.goodsId, itemId = g.itemId, currency = g.currency,
            price = g.price, limit = g.limit, bought = tonumber(bought[g.goodsId]) or 0,
        }
    end
    table.sort(goods, function(a, b) return a.goodsId < b.goodsId end)
    return { err = E.OK, result = { ok = true, goods = goods } }
end

-- u.shopBuy(goodsId, count)
function M.buy(ctx, params)
    local gid = math.floor(tonumber(params.goodsId) or 0)
    local count = math.floor(tonumber(params.count) or 0)
    if count < 1 then return fail("bad_count", { count = count }) end
    local conf = gd.shop(gid)
    if not conf then return fail("goods_not_found", { goodsId = gid }) end

    local activity = ctx.get("activity") or {}
    local shop_sec = progress.section(activity, "shop")
    local bought = shop_sec.bought or {}
    if conf.limit > 0 and (tonumber(bought[gid]) or 0) + count > conf.limit then
        return fail("limit_exceeded", { goodsId = gid, limit = conf.limit })
    end

    local currency = conf.currency
    local price = conf.price * count
    local have = tonumber(ctx.get(currency) or 0)
    if have < price then
        return fail(currency .. "_not_enough", { goodsId = gid, need = price, have = have })
    end

    local changes = { [currency] = have - price }
    local item_conf = gd.item(conf.itemId)
    if item_conf and (item_conf.kind == "gold" or item_conf.kind == "silver") then
        -- 买货币类货品时直接加到对应字段（罕见但语义完整）
        -- 同名字段叠加：currency 与货品 kind 可能相同（金币买金币类货品）
        changes[item_conf.kind] = (changes[item_conf.kind] or tonumber(ctx.get(item_conf.kind) or 0))
                                  + item_conf.value * count
    else
        changes.bag = baglib.add(ctx.get("bag") or {}, conf.itemId, count)
    end

    shop_sec.bought = shop_sec.bought or {}
    shop_sec.bought[gid] = (tonumber(shop_sec.bought[gid]) or 0) + count
    shop_sec.bought = progress.as_object(shop_sec.bought)   -- 数字键映射，形状必须稳定
    changes.activity = progress.with_section(activity, "shop", shop_sec)

    return { err = E.OK, changes = changes, result = {
        ok = true, goodsId = gid, count = count,
        currency = currency, spent = price, itemId = conf.itemId,
    } }
end

local BY_OP = {
    ["u.shopList"] = M.list,
    ["u.shopBuy"]  = M.buy,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "shop: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
