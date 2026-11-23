-- service/handler/rank.lua — 本服排行（U6，只读战力榜）
--
-- 架构决策 D-U6-1（见 U6_M3_DEVLOG §2.1）：复用 P0.5 的全局 hub 服务，
-- 用独立 rankKey 前缀 "local.power" 与跨服榜隔离（单机部署 gid=1，靠 key 区分）。
-- 不新增服务、不加 db 全服遍历命令（db 是薄代理，无 entities 语义）。
-- rankList 先把自己的战力推给 hub，再查第一页，返回降序 rows + me。不写玩家 state。

local schema = require "shared.schema"
local E = schema.errors
local M = {}
local FAIL_CODE = -200
local RANK_KEY = "local.power"

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

-- u.rankList() — 懒提交自己的战力后读榜
function M.list(ctx, params)
    local uid = tostring(ctx.uid() or "")
    if uid == "" or uid == "0" then return fail("no_entity") end
    local power = tonumber(ctx.get("zhanli") or 0) or 0

    -- 推自己的战力。本服榜用 upsert（无 seq 门）：同一秒内战力变化也要立刻生效，
    -- 跨服聚合榜才需要 (sid, seq) 幂等，见 hub.lua 注释。
    local pushed, push_why = ctx.call_hub("upsert", RANK_KEY, uid, uid, power)
    if not pushed then return fail(push_why or "hub_unavailable") end

    local res, why = ctx.call_hub("rank", 1, RANK_KEY, 1, 20)
    if not res then return fail(why or "hub_unavailable") end

    local rows = {}
    for _, row in ipairs(res.rows or {}) do
        rows[#rows + 1] = { uid = row.uid, name = row.name, score = row.score, rank = row.rank }
    end
    local me
    for _, row in ipairs(rows) do if row.uid == uid then me = row break end end
    if not me and res.enabled then
        -- 我不在前 20：拉前 100 兜底（与 cross handler 同口径）
        local full = ctx.call_hub("rank", 1, RANK_KEY, 1, 100)
        for _, row in ipairs((full and full.rows) or {}) do
            if row.uid == uid then me = row break end
        end
    end

    return {
        err = E.OK,
        result = { ok = res.enabled ~= false, enabled = res.enabled ~= false,
                   rows = rows, me = me, rev = res.rev, rankKey = RANK_KEY },
    }
end

local BY_OP = { ["u.rankList"] = M.list }

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "rank: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
