-- service/handler/stage.lua — 关卡批次（U4）
--
-- 迁移自原服 guanka / monster_group 的"逐关推进"语义，但去掉逐帧战斗：
-- 挑战 = 校验门槛 → 服务端结算 → 发经验/金币/掉落 → 推进 clearMax。
-- 进度态存 activity.stage（不新增 schema field，见 U4_DEVLOG §3.1）。
-- 与 fight 共用 shared.award，规则不双写。

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

-- 从 activity 取关卡进度（clearMax / exp）
local function stage_progress(ctx)
    local activity = ctx.get("activity") or {}
    local sec = progress.section(activity, "stage")
    return activity, sec, tonumber(sec.clearMax) or 0, tonumber(sec.exp) or 0
end

-- u.stageInfo() — 只读当前进度与下一关配置
function M.info(ctx, params)
    local _, _, clearMax, exp = stage_progress(ctx)
    local next_conf = nil
    if clearMax < gd.stage_count() then
        local c = gd.stage(clearMax + 1)
        if c then
            next_conf = {
                stageId = c.stageId, needLevel = c.needLevel, needPower = c.needPower,
                exp = c.exp, gold = c.gold, dropItem = c.dropItem, dropNum = c.dropNum,
            }
        end
    end
    return { err = E.OK, result = { ok = true, clearMax = clearMax, exp = exp, next = next_conf } }
end

-- u.stageChallenge(stageId) — 逐关推进，不可跳关
function M.challenge(ctx, params)
    local sid = math.floor(tonumber(params.stageId) or 0)
    local conf = gd.stage(sid)
    if not conf then return fail("stage_not_found", { stageId = sid }) end

    local activity, sec, clearMax, exp = stage_progress(ctx)
    if sid ~= clearMax + 1 then
        return fail("stage_locked", { stageId = sid, clearMax = clearMax })
    end
    local level = tonumber(ctx.get("level") or 0)
    if level < conf.needLevel then
        return fail("level_too_low", { stageId = sid, needLevel = conf.needLevel, level = level })
    end

    local changes, awarded = award.apply_stage(ctx, conf, 1)
    sec.clearMax = sid
    sec.exp = exp + awarded.exp
    changes.activity = progress.with_section(activity, "stage", sec)

    local result = { ok = true, win = true, stageId = sid, clearMax = sid }
    for k, v in pairs(awarded) do result[k] = v end
    return { err = E.OK, changes = changes, result = result }
end

-- u.stageSweep(stageId, times) — 只扫荡已通关关卡，按 times 倍发奖
function M.sweep(ctx, params)
    local sid = math.floor(tonumber(params.stageId) or 0)
    local times = math.floor(tonumber(params.times) or 0)
    if times < 1 then return fail("bad_times", { times = times }) end
    local conf = gd.stage(sid)
    if not conf then return fail("stage_not_found", { stageId = sid }) end

    local activity, sec, clearMax, exp = stage_progress(ctx)
    if sid > clearMax or sid < 1 then
        return fail("stage_not_cleared", { stageId = sid, clearMax = clearMax })
    end

    local changes, awarded = award.apply_stage(ctx, conf, times)
    sec.exp = exp + awarded.exp
    changes.activity = progress.with_section(activity, "stage", sec)

    local result = { ok = true, stageId = sid, times = times }
    for k, v in pairs(awarded) do result[k] = v end
    return { err = E.OK, changes = changes, result = result }
end

local BY_OP = {
    ["u.stageInfo"]      = M.info,
    ["u.stageChallenge"] = M.challenge,
    ["u.stageSweep"]     = M.sweep,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "stage: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
