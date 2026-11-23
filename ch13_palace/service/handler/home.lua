-- service/handler/home.lua — 家园（U6，简化）
--
-- 降级版：只做主城建筑等级 + 升级 + 产出，不做摆件/寻路（CLIENT_V2_DESIGN P1-4）。
-- 进度存 activity.home = { level, harvested }，不新增 schema field。
-- 升级时顺带结算旧等级产出（避免再加一个领取 action）：升级到 L 前先发 L-1 的 produce。
-- 数值来自 home 表（level/upgradeGold/produceItem/produceNum）。

local gd       = require "shared.gamedata"
local progress = require "shared.progress"
local baglib   = require "shared.bag"
local schema   = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200
local MAX_LEVEL = 5

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

local function home_sec(ctx)
    local activity = ctx.get("activity") or {}
    local sec = progress.section(activity, "home")
    if not sec.level then sec.level = 1 end
    return activity, sec
end

-- u.homeInfo() — 只读当前等级、下一级花费、可领产出
function M.info(ctx, params)
    local activity, sec = home_sec(ctx)
    local level = tonumber(sec.level) or 1
    local conf = gd.home(level)
    local next_conf = level < MAX_LEVEL and gd.home(level + 1) or nil
    return {
        err = E.OK,
        result = { ok = true, level = level,
                   upgradeGold = next_conf and next_conf.upgradeGold or 0,
                   produceItem = conf and conf.produceItem or 0,
                   produceNum = conf and conf.produceNum or 0,
                   harvested = sec.harvested or 0, maxLevel = MAX_LEVEL },
    }
end

-- u.homeUpgrade() — 扣金币升 1 级，结算旧等级产出
function M.upgrade(ctx, params)
    local activity, sec = home_sec(ctx)
    local level = tonumber(sec.level) or 1
    if level >= MAX_LEVEL then return fail("max_level", { level = level }) end
    local next_conf = gd.home(level + 1)
    if not next_conf then return fail("home_config_missing", { level = level + 1 }) end

    local gold = tonumber(ctx.get("gold") or 0)
    local cost = next_conf.upgradeGold
    if gold < cost then return fail("gold_not_enough", { gold = gold, cost = cost }) end

    -- 结算旧等级产出（每次升级只结算一次，用 harvested 计数防重）
    local old_conf = gd.home(level)
    local bag = ctx.get("bag") or {}
    local produced = 0
    local harvested = tonumber(sec.harvested) or 0
    if old_conf and harvested < 1 then
        bag = baglib.add(bag, old_conf.produceItem, old_conf.produceNum)
        produced = old_conf.produceNum
        harvested = harvested + 1
    end

    sec.level = level + 1
    sec.harvested = harvested

    return {
        err = E.OK,
        changes = {
            gold = gold - cost,
            bag = bag,
            activity = progress.with_section(activity, "home", sec),
        },
        result = { ok = true, level = level + 1, cost = cost, gold = gold - cost,
                   producedItem = old_conf and old_conf.produceItem or 0, produced = produced },
    }
end

local BY_OP = {
    ["u.homeInfo"]    = M.info,
    ["u.homeUpgrade"] = M.upgrade,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "home: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
