-- service/handler/dev.lua — 测试脚手架（非原工程 op，不计入迁移数量）
--
-- 网关测试、wire 测试和回放对账需要通过 TCP 造初始状态，而在原工程里这些状态
-- 是长期玩法积累出来的。这里提供最小造数口，op 前缀 u.dev.* 明确标识其性质。

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

-- u.dev.heroLv(heroId, lv, tpl, advance, limit)
-- 同时把角色等级抬到不低于该英雄等级，避免升级被 avatar_level_limit 拦住。
function M.hero_lv(ctx, params)
    local heroId = tostring(params.heroId or "")
    local lv = math.floor(tonumber(params.lv) or 0)
    if heroId == "" or lv < 1 then return fail("bad_params") end

    local tpl = math.floor(tonumber(params.tpl) or 2001)
    if not gd.hero(tpl) then return fail("hero_template_missing", { tpl = tpl }) end

    local advance = math.floor(tonumber(params.advance) or 0)
    local limit = math.floor(tonumber(params.limit) or 0)

    local heroes = ctx.get("heroes") or {}
    local out = {}
    for k, v in pairs(heroes) do out[k] = v end
    out[heroId] = { tpl = tpl, lv = lv, exp = 0, advance = advance, limit = limit }

    local changes = { heroes = out }
    local avatar_lv = ctx.get("level") or 1
    if avatar_lv < lv then
        changes.level = lv
        avatar_lv = lv
    end

    return { err = E.OK, changes = changes,
             result = { ok = true, heroId = heroId, lv = lv, tpl = tpl,
                        advance = advance, limit = limit, avatarLv = avatar_lv } }
end

-- u.dev.itemAdd(itemId, count)
function M.item_add(ctx, params)
    local itemId = tonumber(params.itemId)
    local count = math.floor(tonumber(params.count) or 0)
    if not itemId then return fail("bad_item_id") end
    if count == 0 then return fail("bad_count") end
    if not gd.item(itemId) then return fail("item_not_found", { itemId = itemId }) end

    local new_bag = baglib.add(ctx.get("bag") or {}, itemId, count)
    return { err = E.OK, changes = { bag = new_bag },
             result = { ok = true, itemId = itemId, count = baglib.count(new_bag, itemId) } }
end

local BY_OP = {
    ["u.dev.heroLv"]  = M.hero_lv,
    ["u.dev.itemAdd"] = M.item_add,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "dev: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
