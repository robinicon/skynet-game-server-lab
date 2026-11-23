-- service/handler/mission.lua — 任务批次
--
-- 迁移自 palace-game: MissionService.claimMissionReward。
-- 判定顺序与原实现一致：任务不存在 → 已领取 → 未完成 → 发奖并置 claimed。
-- 任务目标、奖励来自 conf/gamedata.xlsx 的 mission 表；完成进度由玩法写入
-- missions[missionId] = { progress, completed, claimed }。

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

local function copy_map(src)
    local out = {}
    for k, v in pairs(src or {}) do
        local one = {}
        for kk, vv in pairs(v) do one[kk] = vv end
        out[k] = one
    end
    return out
end

-- u.missionClaimReward(missionId)
function M.claim(ctx, params)
    local missionId = tonumber(params.missionId)
    if not missionId then return fail("bad_mission_id") end

    local missions = ctx.get("missions") or {}
    local key = missionId  -- 数字键：JSON 往返后 "5001" 会变回 5001
    local rec = missions[key]
    if not rec then return fail("mission_not_found", { missionId = missionId }) end
    if rec.claimed then return fail("already_claimed", { missionId = missionId }) end
    if not rec.completed then
        return fail("not_completed", { missionId = missionId, progress = rec.progress or 0 })
    end

    local conf = gd.mission(missionId)
    if not conf then return fail("mission_config_missing", { missionId = missionId }) end

    local changes = {}
    local result = { ok = true, missionId = missionId, rewardItem = conf.rewardItem, rewardNum = conf.rewardNum }

    local reward = gd.item(conf.rewardItem)
    if not reward then return fail("reward_item_missing", { itemId = conf.rewardItem }) end

    if reward.kind == "gold" or reward.kind == "silver" then
        local add = reward.value * conf.rewardNum
        changes[reward.kind] = (ctx.get(reward.kind) or 0) + add
        result.gain = add
        result.field = reward.kind
    else
        changes.bag = baglib.add(ctx.get("bag") or {}, conf.rewardItem, conf.rewardNum)
        result.gain = conf.rewardNum
        result.field = "bag"
    end

    local new_missions = copy_map(missions)
    new_missions[key].claimed = true
    changes.missions = new_missions

    return { err = E.OK, changes = changes, result = result }
end

local BY_OP = {
    ["u.missionClaimReward"] = M.claim,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "mission: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
