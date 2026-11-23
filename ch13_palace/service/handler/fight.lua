-- service/handler/fight.lua — 战斗批次（U4，结算版）
--
-- 不做逐帧模拟（WebGL 无多线程 → 服务端结算是物理必然，D2）。
-- 胜负由确定性公式判定：power >= needPower；seed 由 stageId 与战力派生（非随机、可复现）。
-- 发奖复用 shared.award（与 stage 同规则，不双写）；战报写 activity.fight.last。

local gd       = require "shared.gamedata"
local progress = require "shared.progress"
local award    = require "shared.award"
local schema   = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

-- 确定性战斗参数：seed / power / needPower / canWin
local function battle_of(ctx, conf)
    local power = gd.power(ctx.get("heroes") or {})
    local seed = conf.stageId * 1000 + power
    local needPower = conf.needPower
    return power, seed, needPower, power >= needPower
end

-- u.fightStart(stageId) — 只读：返回种子与胜负预告（预览只显示"可能范围"，权威在 settle）
function M.start(ctx, params)
    local sid = math.floor(tonumber(params.stageId) or 0)
    local conf = gd.stage(sid)
    if not conf then return fail("stage_not_found", { stageId = sid }) end
    local power, seed, needPower, canWin = battle_of(ctx, conf)
    return { err = E.OK, result = {
        ok = true, stageId = sid, seed = seed,
        power = power, needPower = needPower, canWin = canWin,
    } }
end

-- u.fightSettle(stageId) — 服务端权威结算
function M.settle(ctx, params)
    local sid = math.floor(tonumber(params.stageId) or 0)
    local conf = gd.stage(sid)
    if not conf then return fail("stage_not_found", { stageId = sid }) end

    local power, seed, needPower, canWin = battle_of(ctx, conf)
    local activity = ctx.get("activity") or {}
    local fight_sec = { last = { stageId = sid, seed = seed, power = power,
                                 needPower = needPower, win = canWin } }

    local result = { ok = true, stageId = sid, seed = seed,
                     power = power, needPower = needPower, win = canWin }
    local changes = {}

    if canWin then
        -- 与 stageChallenge 共用发奖 + 推进 clearMax
        local stage_sec = progress.section(activity, "stage")
        local clearMax = tonumber(stage_sec.clearMax) or 0
        -- 只在首次通关该关时推进，重复打旧关仍发奖但不回退 clearMax
        if sid == clearMax + 1 then
            stage_sec.clearMax = sid
        end
        stage_sec.exp = (tonumber(stage_sec.exp) or 0)
        local awarded
        changes, awarded = award.apply_stage(ctx, conf, 1)
        stage_sec.exp = stage_sec.exp + awarded.exp
        for k, v in pairs(awarded) do result[k] = v end
        changes.activity = progress.with_section(activity, "stage", stage_sec)
    end

    -- 战报无论胜负都写（结算与回放分离，战报是独立读路径）
    local act_for_fight = changes.activity or activity
    changes.activity = progress.with_section(act_for_fight, "fight", fight_sec)

    return { err = E.OK, changes = changes, result = result }
end

local BY_OP = {
    ["u.fightStart"]  = M.start,
    ["u.fightSettle"] = M.settle,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "fight: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
