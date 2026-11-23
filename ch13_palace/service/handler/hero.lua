-- service/handler/hero.lua — 将星养成批次（英雄养成）
--
-- 迁移自 palace-game: HeroService.updateHeroLv / heroAdvanceLv / heroLimitLv。
-- 原实现的判定顺序与消耗来源保持一致：
--   升级：先查角色等级上限 → 英雄等级上限 → 加官等级上限 → 按档位吞经验丹 → 溢出经验留在英雄身上
--   加官：当前加官档的 lvLimit 达到后才可升，消耗取 hero_surmount.costItem/Num
--   进爵：要求 advance >= breakLvLimit，消耗取 hero_week.costItem/Num
-- 所有数值来自 conf/gamedata.xlsx，不在此处硬编码。

local gd     = require "shared.gamedata"
local baglib = require "shared.bag"
local schema = require "shared.schema"

local E = schema.errors
local M = {}

local FAIL_CODE = -200 -- 业务失败（参数/前置条件不满足），与协议层 -100/-101 区分

local function fail(reason, extra)
    local r = { ok = false, reason = reason }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { err = FAIL_CODE, result = r }
end

local function heroes_of(ctx)
    return ctx.get("heroes") or {}
end

local function replace(heroes, heroId, h)
    local out = {}
    for k, v in pairs(heroes) do out[k] = v end
    out[heroId] = h
    return out
end

local function copy_hero(h)
    return { tpl = h.tpl, lv = h.lv, exp = h.exp or 0,
             advance = h.advance or 0, limit = h.limit or 0 }
end

-- 原 getHeroElixirCost：按小→中→大 逐档吞，最后可能溢出（溢出经验保留）
local function elixir_cost(bag, need_exp)
    local cost, gained = {}, 0
    for _, tier in ipairs(gd.elixir_tiers()) do
        if gained >= need_exp then break end
        local have = baglib.count(bag, tier.templateId)
        if have > 0 then
            local n = math.ceil((need_exp - gained) / tier.value)
            if n > have then n = have end
            if n > 0 then
                cost[tostring(tier.templateId)] = n
                gained = gained + n * tier.value
            end
        end
    end
    return cost, gained
end

-- u.heroUpdateLvAuto(heroId, auto)
function M.update_lv(ctx, params)
    local heroId = tostring(params.heroId or "")
    local auto = (params.auto == true or params.auto == 1)
    local heroes = heroes_of(ctx)
    local h = heroes[heroId]
    if not h then return fail("hero_not_found", { heroId = heroId }) end

    local tpl = gd.hero(h.tpl)
    if not tpl then return fail("hero_template_missing", { tpl = h.tpl }) end

    local avatar_lv = ctx.get("level") or 1
    local max_lv = gd.hero_max_lv()
    local gate = gd.surmount(h.tpl, h.advance or 0)
    local level_limit = (gate and gate.lvLimit) or math.min(tpl.maxLv, max_lv)
    if level_limit > max_lv then level_limit = max_lv end

    if h.lv >= avatar_lv then
        return fail("avatar_level_limit", { lv = h.lv, avatarLv = avatar_lv })
    end
    if h.lv >= max_lv then
        return fail("hero_level_max", { lv = h.lv, maxLv = max_lv })
    end
    if h.lv >= level_limit then
        return fail("advance_level_limit", { lv = h.lv, levelLimit = level_limit, advance = h.advance or 0 })
    end

    local to_lv
    if auto then
        to_lv = math.min(avatar_lv, max_lv)
        if to_lv > level_limit then to_lv = level_limit end
        if to_lv <= h.lv then return fail("no_gain", { lv = h.lv }) end
    else
        to_lv = math.min(avatar_lv, h.lv + 1)
    end

    local step_exp = gd.hero_need_exp(h.lv, to_lv)
    if not step_exp then return fail("exp_table_missing", { from = h.lv, to = to_lv }) end
    local need_exp = step_exp - (h.exp or 0)
    if need_exp <= 0 then return fail("no_exp_needed", { lv = h.lv, exp = h.exp or 0 }) end

    local cur_bag = ctx.get("bag") or {}
    local cost, gained = elixir_cost(cur_bag, need_exp)
    if gained <= 0 then
        return fail("elixir_not_enough", { needExp = need_exp })
    end

    local new_bag, missing = baglib.consume(cur_bag, cost)
    if not new_bag then return fail("elixir_not_enough", { missing = missing }) end

    local nh = copy_hero(h)
    nh.exp = (h.exp or 0) + gained
    while nh.lv < to_lv do
        local one = gd.hero_need_exp(nh.lv, nh.lv + 1)
        if not one or nh.exp < one then break end
        nh.exp = nh.exp - one
        nh.lv = nh.lv + 1
    end

    return {
        err = E.OK,
        changes = { heroes = replace(heroes, heroId, nh), bag = new_bag },
        result = {
            ok = true, heroId = heroId, lv = nh.lv, exp = nh.exp,
            cost = cost, gainedExp = gained, needExp = need_exp, toLv = to_lv,
        },
    }
end

-- u.heroUpdateAdvanceLv(heroId) — 加官
function M.advance(ctx, params)
    local heroId = tostring(params.heroId or "")
    local heroes = heroes_of(ctx)
    local h = heroes[heroId]
    if not h then return fail("hero_not_found", { heroId = heroId }) end
    if not gd.hero(h.tpl) then return fail("hero_template_missing", { tpl = h.tpl }) end

    local adv = h.advance or 0
    local gate = gd.surmount(h.tpl, adv)
    if not gate then return fail("advance_gate_missing", { advance = adv }) end
    if not gd.next_surmount(h.tpl, adv) then
        return fail("advance_max", { advance = adv })
    end
    if h.lv < gate.lvLimit then
        return fail("level_not_enough", { lv = h.lv, needLv = gate.lvLimit })
    end

    local cost = gd.gate_cost(gate)
    local cur_bag = ctx.get("bag") or {}
    local ok, missing = baglib.has(cur_bag, cost)
    if not ok then return fail("item_not_enough", { missing = missing }) end
    local new_bag = baglib.consume(cur_bag, cost)

    local nh = copy_hero(h)
    nh.advance = adv + 1

    return {
        err = E.OK,
        changes = { heroes = replace(heroes, heroId, nh), bag = new_bag },
        result = { ok = true, heroId = heroId, advance = nh.advance,
                   nextLvLimit = (gd.surmount(h.tpl, nh.advance) or {}).lvLimit, cost = cost },
    }
end

-- u.heroUpdateLimitLv(heroId) — 进爵
function M.limit(ctx, params)
    local heroId = tostring(params.heroId or "")
    local heroes = heroes_of(ctx)
    local h = heroes[heroId]
    if not h then return fail("hero_not_found", { heroId = heroId }) end
    if not gd.hero(h.tpl) then return fail("hero_template_missing", { tpl = h.tpl }) end

    local cur = h.limit or 0
    local gate = gd.week(h.tpl, cur)
    if not gate then return fail("limit_gate_missing", { limit = cur }) end
    if not gd.next_week(h.tpl, cur) then
        return fail("limit_max", { limit = cur })
    end
    if (h.advance or 0) < gate.breakLvLimit then
        return fail("advance_not_enough", { advance = h.advance or 0, needAdvance = gate.breakLvLimit })
    end

    local cost = gd.gate_cost(gate)
    local cur_bag = ctx.get("bag") or {}
    local ok, missing = baglib.has(cur_bag, cost)
    if not ok then return fail("item_not_enough", { missing = missing }) end
    local new_bag = baglib.consume(cur_bag, cost)

    local nh = copy_hero(h)
    nh.limit = cur + 1

    return {
        err = E.OK,
        changes = { heroes = replace(heroes, heroId, nh), bag = new_bag },
        result = { ok = true, heroId = heroId, limit = nh.limit, cost = cost },
    }
end

local BY_OP = {
    ["u.heroUpdateLvAuto"]    = M.update_lv,
    ["u.heroUpdateAdvanceLv"] = M.advance,
    ["u.heroUpdateLimitLv"]   = M.limit,
}

function M.handle(ctx, action, params)
    local fn = BY_OP[action.op]
    if not fn then
        return { err = E.UNKNOWN_OP, result = { ok = false, reason = "hero: no handler for " .. tostring(action.op) } }
    end
    return fn(ctx, params)
end

return M
