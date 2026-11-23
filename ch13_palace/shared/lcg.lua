-- shared/lcg.lua — 确定性线性同余随机（U6 抽卡用）
--
-- 不用 math.random：跨进程/跨语言不可复现，对账样本无法固定期望。
-- seed 由玩家抽奖次数派生（见 gacha handler），同 seed 必同结果，样本 derivation 可逐条记录。
-- 全程整数运算（Lua 5.3 64 位整数），不经过 double，避免 U0 的 long 精度坑。

local M = {}

local MULT = 1103515245
local INC  = 12345
local MOD  = 2147483648  -- 2^31

-- 由 drawSeq 生成 [0, MOD) 的确定性值
function M.next(drawSeq)
    local s = (math.floor(tonumber(drawSeq) or 0) * MULT + INC) % MOD
    if s < 0 then s = s + MOD end
    return s
end

-- 把 [0,MOD) 的值映射到 [0,1) 浮点（仅用于 UI 展示，不参与规则判定）
function M.unit(drawSeq)
    return M.next(drawSeq) / MOD
end

-- 按权重选择：tiers = { {key=, weight=}, ... }，rng 值 ∈ [0,MOD)
-- 用整数权重累加，避免浮点误差导致边界项永不命中。
function M.pick_weighted(tiers, rng)
    local total = 0
    for _, t in ipairs(tiers) do total = total + t.weight end
    if total <= 0 then return nil end
    local x = rng % total
    local acc = 0
    for _, t in ipairs(tiers) do
        acc = acc + t.weight
        if x < acc then return t.key end
    end
    return tiers[#tiers].key  -- 兜底（浮点边界不该到这）
end

return M
