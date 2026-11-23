-- service/handler/cross.lua — 跨服排行（P0.5 最小链路）
--
-- 两个动作，全部经 ctx.call_hub 调跨服中心，不直接持有服务地址、不碰玩家 state：
--   u.crossSubmit(rankKey, score) -> { ok, rank, rev }
--   u.crossRank(rankKey, page)    -> { ok, rows, me, rev, enabled, reason }
-- gid 单机固定 1；sid 用玩家 uid 作逻辑提交键（幂等键 (sid,seq) 的本意是区分提交者，
-- 单机下以 uid 保证不同玩家互不干扰；真实多 zone 部署时由网关注入真实 zone sid）。
-- seq 用秒级时间戳：同玩家同秒内的重复提交会被 hub 幂等吞掉，排行是"更新分数"语义，可接受。

local schema = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

-- u.crossSubmit(rankKey, score)
function M.submit(ctx, params)
    local rankKey = tostring(params.rankKey or "default")
    local score = tonumber(params.score) or 0
    local uid = tostring(ctx.uid() or "")
    if uid == "" or uid == "0" then return fail("no_entity") end

    local res, why = ctx.call_hub("submit", 1, uid, os.time(), rankKey, uid, score)
    if not res then return fail(why or "hub_unavailable") end
    return {
        err = E.OK,
        -- 排行是跨服状态，不写玩家 state，故无 changes / delta
        result = { ok = res.ok, rank = res.rank, rev = res.rev,
                   enabled = res.enabled, reason = res.reason },
    }
end

-- u.crossRank(rankKey, page)
function M.rank(ctx, params)
    local rankKey = tostring(params.rankKey or "default")
    local page = tonumber(params.page) or 1

    local res, why = ctx.call_hub("rank", 1, rankKey, page, 20)
    if not res then return fail(why or "hub_unavailable") end
    if not res.ok then
        -- 开关关闭：返回可读原因，客户端灰入口而非报错（result.ok=false + reason）
        return { err = E.OK, result = { ok = false, enabled = false,
                 reason = res.reason, rows = {}, rev = res.rev, me = nil } }
    end

    -- hub.rank 接口不含 uid；me（我的名次）由 handler 用 ctx.uid 从全榜补齐。
    local my_uid = tostring(ctx.uid() or "")
    local me
    local all = res.rows
    for _, row in ipairs(all) do
        if row.uid == my_uid then me = row break end
    end
    if not me then
        local full = ctx.call_hub("rank", 1, rankKey, 1, 100)
        for _, row in ipairs((full and full.rows) or {}) do
            if row.uid == my_uid then me = row break end
        end
    end

    return {
        err = E.OK,
        result = { ok = true, enabled = true, rows = res.rows, me = me, rev = res.rev },
    }
end

local BY_OP = {
    ["u.crossSubmit"] = M.submit,
    ["u.crossRank"]   = M.rank,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "cross: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
