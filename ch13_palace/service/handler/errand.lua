-- service/handler/errand.lua — 经营·办差（U6，简化）
--
-- 降级版：不做货架/计时/加速——"派遣即完成"，领取即发奖（CLIENT_V2_DESIGN P1-5）。
-- 进度存 activity.errand = { claimed = { [errandId]=true } }，不新增 schema field。
-- 奖励 = 表里的 gold + itemId/itemNum；itemId 若是 gold/silver 类则走货币字段，否则走 bag。
-- 数值来自 errand 表；重复领取返回 already_claimed（降级版不刷新增）。

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

local function errand_sec(ctx)
    local activity = ctx.get("activity") or {}
    return activity, progress.section(activity, "errand")
end

-- u.errandList() — 只读差事与已完成标记
function M.list(ctx, params)
    local activity, sec = errand_sec(ctx)
    local claimed = sec.claimed or {}
    local rows = {}
    for _, id in ipairs(gd.errand_ids()) do
        local conf = gd.errand(id)
        rows[#rows + 1] = { id = id, gold = conf.gold, itemId = conf.itemId,
                            itemNum = conf.itemNum, claimed = claimed[id] and true or false }
    end
    return { err = E.OK, result = { ok = true, rows = rows } }
end

-- u.errandClaim(errandId) — 领取一档奖励，防重复
function M.claim(ctx, params)
    local id = math.floor(tonumber(params.errandId) or 0)
    local conf = gd.errand(id)
    if not conf then return fail("errand_not_found", { errandId = id }) end

    local activity, sec = errand_sec(ctx)
    local claimed = sec.claimed or {}
    if claimed[id] then return fail("already_claimed", { errandId = id }) end

    local changes = {}
    local result = { ok = true, errandId = id, gold = conf.gold,
                     itemId = conf.itemId, itemNum = conf.itemNum }

    -- 固定 gold 奖励
    changes.gold = (tonumber(ctx.get("gold") or 0)) + conf.gold
    -- itemId 奖励按 kind 路由（9001 gold / 9002 silver 走字段，其余走背包）
    local item = gd.item(conf.itemId)
    if item and (item.kind == "gold" or item.kind == "silver") then
        -- 必须叠加在 changes 已写的同名字段上：固定 gold 奖励与货币类道具会落在同一个键，
        -- 直接用 ctx.get() 起算会把前面那笔固定奖励覆盖掉（对账已抓到，1300 变 1000）。
        changes[item.kind] = (changes[item.kind] or tonumber(ctx.get(item.kind) or 0))
                             + item.value * conf.itemNum
        result[item.kind .. "Gain"] = item.value * conf.itemNum
    else
        changes.bag = baglib.add(ctx.get("bag") or {}, conf.itemId, conf.itemNum)
    end

    claimed[id] = true
    sec.claimed = progress.as_object(claimed)   -- 数字键映射，形状必须稳定
    changes.activity = progress.with_section(activity, "errand", sec)

    return { err = E.OK, changes = changes, result = result }
end

local BY_OP = {
    ["u.errandList"]  = M.list,
    ["u.errandClaim"] = M.claim,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "errand: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
