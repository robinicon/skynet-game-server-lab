-- service/handler/gacha.lua — 抽卡（U6）
--
-- 降级版：确定性 LCG（无真随机）+ 10 抽保底 + 扣金币。
-- 进度存 activity.gacha = { draws=, pity=, last= }，不新增 schema field。
-- 获得新英雄 → heroes map 加实例（id 用 tpl+drawSeq 确定性生成）；
-- 重复英雄 → 金币补偿（降级版不做碎片系统）。数值来自 gamedata gacha 表 + meta cost/pity。

local gd       = require "shared.gamedata"
local lcg      = require "shared.lcg"
local progress = require "shared.progress"
local schema   = require "shared.schema"

local E = schema.errors
local M = {}
local FAIL_CODE = -200

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

local function gacha_sec(ctx)
    local activity = ctx.get("activity") or {}
    return activity, progress.section(activity, "gacha")
end

-- u.gachaDraw() — 扣金币抽一次，确定性选择英雄档位
function M.draw(ctx, params)
    local cost = gd.gacha_cost()
    local gold = tonumber(ctx.get("gold") or 0)
    if gold < cost then return fail("gold_not_enough", { gold = gold, cost = cost }) end

    local activity, sec = gacha_sec(ctx)
    local draws = tonumber(sec.draws) or 0
    local pity = tonumber(sec.pity) or 0
    local next_draw = draws + 1
    local pity_limit = gd.gacha_pity()

    -- 构造权重表；LCG 值来自 next_draw（确定性，可复现）
    local tiers = {}
    for tpl, conf in pairs(gd.gacha_tiers()) do
        tiers[#tiers + 1] = { key = tpl, weight = conf.weight, rare = conf.rare }
    end
    -- 必须排序：pairs 遍历顺序不保证，权重累加区间会漂移，跨进程对账不可复现。
    table.sort(tiers, function(a, b) return a.key < b.key end)
    local rng = lcg.next(next_draw)
    local tpl = lcg.pick_weighted(tiers, rng)
    local conf = gd.gacha(tpl)

    -- 保底：连续 (pity_limit-1) 抽未出稀有 → 本次强制稀有档
    local forced = false
    if pity >= pity_limit - 1 then
        forced = true
        for _, t in ipairs(tiers) do
            if t.rare == 1 then tpl = t.key; conf = gd.gacha(tpl); break end
        end
    end
    local rare = conf and conf.rare == 1
    if rare then pity = 0 else pity = pity + 1 end

    -- 发奖：新 tpl → heroes 实例；重复 → 金币补偿 50
    local heroes = ctx.get("heroes") or {}
    local new_hero_id = "g" .. tostring(tpl) .. "_" .. tostring(next_draw)
    local duplicate = false
    for _, h in pairs(heroes) do
        if tonumber(h.tpl) == tonumber(tpl) then duplicate = true; break end
    end
    local new_gold = gold - cost
    if duplicate then new_gold = new_gold + 50 end
    local new_heroes
    if duplicate then
        new_heroes = heroes
    else
        new_heroes = {}
        for k, v in pairs(heroes) do new_heroes[k] = v end
        new_heroes[new_hero_id] = { tpl = tpl, lv = 1, exp = 0, advance = 0, limit = 0 }
    end

    -- 写进度
    sec.draws = next_draw
    sec.pity = pity
    sec.last = { tpl = tpl, rare = rare and 1 or 0, forced = forced and 1 or 0, rng = rng }

    return {
        err = E.OK,
        changes = {
            gold = new_gold,
            heroes = new_heroes,
            activity = progress.with_section(activity, "gacha", sec),
        },
        result = { ok = true, tpl = tpl, rare = rare, forced = forced,
                   pity = pity, draws = next_draw, cost = cost,
                   duplicate = duplicate, gold = new_gold },
    }
end

local BY_OP = { ["u.gachaDraw"] = M.draw }

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "gacha: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
