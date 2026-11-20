-- shared/workload.lua — 业务对象定义与模拟操作
--
-- 三组真实业务对象 + 一组反例对象，用于验证"池化不是万能的"。
--
-- 选型原则（design.md Phase 2）：
--   高频对象：协议包、AOI 临时实体、伤害事件 → 池化
--   低频对象：账号、角色、任务配置 → 不池化（常驻，本来就不释放）
--   变长对象：见 heavy 反例 —— reset 成本随使用规模线性增长，池化可能是负优化

local M = {}

-- ============================================================
-- 1. packet — 协议包（高频、短命、结构固定）
-- ============================================================
M.packet = {
    name = "packet",
    factory = function()
        return {
            cmd     = 0,
            session = 0,
            uid     = 0,
            payload = nil,
            ts      = 0,
        }
    end,
    reset = function(o)
        o.cmd     = 0
        o.session = 0
        o.uid     = 0
        o.payload = nil
        o.ts      = 0
    end,
    -- 模拟一次业务使用：填字段 + 读字段
    use = function(o, i)
        o.cmd = 1
        o.session = i
        o.uid = 1000 + (i % 64)
        o.payload = "x"
        o.ts = i
        return o.session + o.uid
    end,
}

-- ============================================================
-- 2. aoi_entity — AOI 临时实体（含嵌套数组）
-- ============================================================
M.aoi_entity = {
    name = "aoi_entity",
    factory = function()
        return {
            id        = 0,
            x         = 0,
            y         = 0,
            neighbors = {},      -- 嵌套数组：new 时需要额外分配
        }
    end,
    reset = function(o)
        o.id = 0
        o.x  = 0
        o.y  = 0
        local n = o.neighbors
        for i = #n, 1, -1 do
            n[i] = nil
        end
    end,
    use = function(o, i)
        o.id = i
        o.x = i % 1000
        o.y = (i * 7) % 1000
        for k = 1, 8 do
            o.neighbors[k] = i * 8 + k
        end
        return o.id
    end,
}

-- ============================================================
-- 3. damage_event — 战斗伤害事件（含数组，高频）
-- ============================================================
M.damage_event = {
    name = "damage_event",
    factory = function()
        return {
            attacker = 0,
            target   = 0,
            value    = 0,
            flags    = {},
        }
    end,
    reset = function(o)
        o.attacker = 0
        o.target   = 0
        o.value    = 0
        local f = o.flags
        for i = #f, 1, -1 do
            f[i] = nil
        end
    end,
    use = function(o, i)
        o.attacker = i % 32
        o.target   = (i + 1) % 32
        o.value    = 100 + (i % 50)
        for k = 1, 4 do
            o.flags[k] = k
        end
        return o.value
    end,
}

-- ============================================================
-- 4. heavy — 反例：变长对象，reset 成本随使用规模线性增长
--
-- factory 只建一个空壳（1 个字段，极便宜）；
-- 但每次使用会往 items 里塞 SCALE 个元素，reset 必须逐个清空。
--
-- 结论（见 bench 场景 C）：这类对象池化是**负优化**。
-- 正确做法：不池化，或让 reset 只清理"已用长度"并复用数组容量时，
-- 需先确认 avg_used × reset_unit < new_cost。
-- ============================================================
local HEAVY_SCALE = 200

M.heavy = {
    name = "heavy",
    scale = HEAVY_SCALE,
    factory = function()
        return { items = {} }     -- 空壳
    end,
    reset = function(o)
        local n = o.items
        for i = #n, 1, -1 do
            n[i] = nil
        end
    end,
    use = function(o, i)
        local n = o.items
        for k = 1, HEAVY_SCALE do
            n[k] = i + k
        end
        return HEAVY_SCALE
    end,
}

--- 所有定义（供测试遍历）
M.all = { M.packet, M.aoi_entity, M.damage_event, M.heavy }

return M
