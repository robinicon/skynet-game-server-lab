-- shared/gamedata.lua — 游戏内容配置访问层
--
-- 数据只有 fid / 模板 id；英雄等级上限、经验曲线、加官消耗、道具效果、任务奖励
-- 全部来自 conf/gamedata.xlsx 的生成物。业务 handler 只在这里查表，不硬编码数值。

local gd = require "generated.gamedata_generated"

local M = {
    raw = gd,
    version = gd.version,
}

function M.hero(tpl)
    return gd.hero[tonumber(tpl) or -1]
end

function M.item(tpl)
    return gd.item[tonumber(tpl) or -1]
end

function M.mission(id)
    return gd.mission[tonumber(id) or -1]
end

function M.stage(id)
    return gd.stage[tonumber(id) or -1]
end

function M.stage_count()
    local n = 0
    for _ in pairs(gd.stage) do n = n + 1 end
    return n
end

function M.shop(goodsId)
    return gd.shop[tonumber(goodsId) or -1]
end

function M.sign(day)
    return gd.sign[tonumber(day) or -1]
end

function M.online(minutes)
    return gd.online[tonumber(minutes) or -1]
end

-- U6 M3 玩法访问器
function M.gacha(tpl)
    return gd.gacha[tonumber(tpl) or -1]
end

function M.gacha_tiers()
    return gd.gacha
end

function M.gacha_cost()
    return gd.gacha_cost or 100
end

function M.gacha_pity()
    return gd.gacha_pity or 10
end

function M.home(level)
    return gd.home[tonumber(level) or -1]
end

function M.errand(id)
    return gd.errand[tonumber(id) or -1]
end

function M.errand_ids()
    local ids = {}
    for id in pairs(gd.errand) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

-- 由英雄表算战力：Σ(quality*10 + lv*5 + advance*2 + limit)，与规则文档 §3.3 一致
function M.power(heroes)
    local total = 0
    for _, h in pairs(heroes or {}) do
        local conf = M.hero(h.tpl)
        if conf then
            total = total + conf.quality * 10 + (tonumber(h.lv) or 0) * 5
                    + (tonumber(h.advance) or 0) * 2 + (tonumber(h.limit) or 0)
        end
    end
    return total
end

function M.hero_max_lv()
    return gd.hero_max_lv
end

-- 升到 toLv 所需的累计经验；与原工程 DataUtils.getHeroUpLvNeedExp 同义：
-- 逐级累加 HeroExpData[lv].experience，区间 [fromLv, toLv)
function M.hero_need_exp(fromLv, toLv)
    fromLv, toLv = tonumber(fromLv) or 0, tonumber(toLv) or 0
    if fromLv <= 0 or fromLv > toLv then return 0, "bad level range" end
    local total = 0
    for lv = fromLv, toLv - 1 do
        local exp = gd.hero_exp[lv]
        if not exp then return nil, "no hero_exp for lv " .. tostring(lv) end
        total = total + exp
    end
    return total
end

-- 加官门槛：当前加官等级对应的等级上限与升到下一级的消耗
function M.surmount(tpl, advance)
    local t = gd.hero_surmount[tonumber(tpl) or -1]
    return t and t[tonumber(advance) or -1] or nil
end

function M.next_surmount(tpl, advance)
    local t = gd.hero_surmount[tonumber(tpl) or -1]
    return t and t[(tonumber(advance) or -1) + 1] or nil
end

-- 进爵门槛：当前进爵等级要求的加官等级与升到下一级的消耗
function M.week(tpl, limit)
    local t = gd.hero_week[tonumber(tpl) or -1]
    return t and t[tonumber(limit) or -1] or nil
end

function M.next_week(tpl, limit)
    local t = gd.hero_week[tonumber(tpl) or -1]
    return t and t[(tonumber(limit) or -1) + 1] or nil
end

-- 经验丹档位，按单颗经验从低到高（与 Java 小/中/大 的消耗顺序一致）
function M.elixir_tiers()
    return gd.elixir_tiers
end

-- 把 gate 的 costItem/costNum 转成 { [templateId] = count }
function M.gate_cost(gate)
    if not gate then return nil end
    local item = M.item(gate.costItem)
    if not item then return nil, "cost item " .. tostring(gate.costItem) .. " missing" end
    return { [tostring(gate.costItem)] = gate.costNum }
end

return M
