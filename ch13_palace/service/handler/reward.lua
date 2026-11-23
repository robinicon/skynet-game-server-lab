-- service/handler/reward.lua — 签到 / 在线奖励批次（U4）
--
-- 表驱动：sign / online 表来自 conf/gamedata.xlsx。
-- 进度态存 activity.reward（signDay / onlineMin / onlineClaimed，不新增 field）。
-- 签到日由客户端参数声明（day 1..7），服务端校验连续性 + 防重，回放可复现。

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

-- 把一次奖励（itemId/count）写进 changes，返回 result 描述（与 mission 同语义）
local function grant(ctx, item_id, count, reward_sec, activity, changes)
    local item = gd.item(item_id)
    if not item then return nil, fail("reward_item_missing", { itemId = item_id }) end
    local result = { ok = true, itemId = item_id, count = count }
    if item.kind == "gold" or item.kind == "silver" then
        local gain = item.value * count
        -- 同名字段叠加：一次发奖里多笔同类货币不能互相覆盖
        changes[item.kind] = (changes[item.kind] or tonumber(ctx.get(item.kind) or 0)) + gain
        result.gain = gain
        result.field = item.kind
    else
        changes.bag = baglib.add(ctx.get("bag") or {}, item_id, count)
        result.gain = count
        result.field = "bag"
    end
    changes.activity = progress.with_section(activity, "reward", reward_sec)
    return result
end

local function reward_sec(ctx)
    local activity = ctx.get("activity") or {}
    return activity, progress.section(activity, "reward")
end

-- u.rewardSign(day) — day ∈ [1,7]，必须等于 signDay+1（7→1 循环）
function M.sign(ctx, params)
    local day = math.floor(tonumber(params.day) or 0)
    if day < 1 or day > 7 then return fail("bad_sign_day", { day = day }) end
    local conf = gd.sign(day)
    if not conf then return fail("sign_config_missing", { day = day }) end

    local activity, sec = reward_sec(ctx)
    local signDay = tonumber(sec.signDay) or 0
    if day == signDay then
        return fail("already_signed", { day = day })
    end
    local expected = signDay % 7 + 1
    if day ~= expected then
        return fail("sign_day_mismatch", { day = day, expected = expected })
    end

    local changes = {}
    sec.signDay = day
    local result, err = grant(ctx, conf.itemId, conf.count, sec, activity, changes)
    if err then return err end
    result.day = day
    return { err = E.OK, changes = changes, result = result }
end

-- u.rewardOnline(minutes) — 达到在线时长且该档位未领过
function M.online(ctx, params)
    local minutes = math.floor(tonumber(params.minutes) or 0)
    local conf = gd.online(minutes)
    if not conf then return fail("online_tier_not_found", { minutes = minutes }) end

    local activity, sec = reward_sec(ctx)
    local claimed = sec.onlineClaimed or {}
    if claimed[minutes] then
        return fail("already_claimed", { minutes = minutes })
    end
    local onlineMin = tonumber(sec.onlineMin) or 0
    if onlineMin < minutes then
        return fail("online_time_not_enough", { minutes = minutes, onlineMin = onlineMin })
    end

    local changes = {}
    claimed[minutes] = true
    sec.onlineClaimed = progress.as_object(claimed)   -- 数字键映射，形状必须稳定
    local result, err = grant(ctx, conf.itemId, conf.count, sec, activity, changes)
    if err then return err end
    result.minutes = minutes
    return { err = E.OK, changes = changes, result = result }
end

local BY_OP = {
    ["u.rewardSign"]   = M.sign,
    ["u.rewardOnline"] = M.online,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "reward: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
