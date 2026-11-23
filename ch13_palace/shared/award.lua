-- shared/award.lua — U4 关卡奖励发放（stage 与 fight 共用，避免规则双写）
--
-- 结算是服务端单方面权威；数值全来自 conf/gamedata.xlsx 的 stage 表（确定性，无随机）。
-- 本模块只算"发放量 + 新的 gold/bag"，activity.stage 的推进由各 handler 组合。

local gd     = require "shared.gamedata"
local baglib = require "shared.bag"

local M = {}

-- 按 stage 配置发放 times 倍奖励。
-- 返回 { changes={gold=,bag=}, result={exp=,gold=,dropItem=,dropNum=} }
function M.apply_stage(ctx, conf, times)
    times = math.max(1, math.floor(tonumber(times) or 1))
    local exp_gain  = conf.exp * times
    local gold_gain = conf.gold * times
    local drop_gain = conf.dropNum * times

    local changes = {
        gold = (ctx.get("gold") or 0) + gold_gain,
        bag  = baglib.add(ctx.get("bag") or {}, conf.dropItem, drop_gain),
    }
    local result = {
        exp = exp_gain, gold = gold_gain,
        dropItem = conf.dropItem, dropNum = drop_gain,
    }
    return changes, result
end

return M
