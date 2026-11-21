-- shared/ecs_low.lua — 低频 ECS（Lua 实现）
--
-- 定位（design.md Phase 3）：
--   低频 CRUD 型逻辑（背包、任务、装备、社交）用 Lua ECS —— 灵活、可读、可热更。
--   高频逻辑（战斗 tick、AOI 实时更新）用 C ECS —— 见 src/ecs_high.c。
--
-- 数据结构：
--   Entity    = 整数 id（自增）
--   Component = table，按名字挂到 entity 上
--   System    = 遍历函数（each）或专用函数（tick）
--
-- ⚠️ 性能提示（基准见 test/bench_ecs.lua）：
--   通用 `each(names, fn)` 每次迭代都会构造参数表 + 多次哈希查找，
--   在高频路径上比专用 `tick()` 慢一个数量级。
--   **这是 Lua ECS 不能用于战斗 tick 的根本原因**，不是 Lua 本身慢。

local M = {}

local World = {}
World.__index = World

--- 创建世界
function M.new()
    return setmetatable({
        next_id = 1,
        comps   = {},     -- eid → { [comp_name] = data }
        n       = 0,      -- 存活 entity 数
    }, World)
end

--- 创建实体
function World:create()
    local id = self.next_id
    self.next_id = id + 1
    self.comps[id] = {}
    self.n = self.n + 1
    return id
end

--- 销毁实体
function World:destroy(eid)
    if self.comps[eid] == nil then
        return false
    end
    self.comps[eid] = nil
    self.n = self.n - 1
    return true
end

--- 添加组件
function World:add(eid, name, data)
    local e = self.comps[eid]
    if not e then return false end
    e[name] = data
    return true
end

--- 移除组件
function World:remove(eid, name)
    local e = self.comps[eid]
    if not e or e[name] == nil then return false end
    e[name] = nil
    return true
end

--- 读取组件
function World:get(eid, name)
    local e = self.comps[eid]
    if not e then return nil end
    return e[name]
end

function World:has(eid, name)
    local e = self.comps[eid]
    return e ~= nil and e[name] ~= nil
end

function World:exists(eid)
    return self.comps[eid] ~= nil
end

function World:count()
    return self.n
end

--- 通用遍历：找出同时拥有 names 中所有组件的实体
-- @param names array  组件名列表
-- @param fn    function(eid, comp1, comp2, ...)
--
-- 注意：每次迭代都要构造一张参数表（table.pack + unpack），
-- 这正是它不适合高频路径的原因。高频请用专用 tick()。
function World:each(names, fn)
    local n_names = #names
    for eid, comps in pairs(self.comps) do
        local args = {}
        local ok = true
        for i = 1, n_names do
            local c = comps[names[i]]
            if c == nil then
                ok = false
                break
            end
            args[i] = c
        end
        if ok then
            fn(eid, table.unpack(args, 1, n_names))
        end
    end
end

--- 专用系统：移动 + 边界反弹 + 血量回复
-- 与 C 版 ecs_update 逻辑完全一致，用于同口径性能对比。
-- 直接访问字段、不构造临时表，是 Lua 能达到的最快写法。
function World:tick(dt, bound)
    for _, comps in pairs(self.comps) do
        local pos = comps.position
        local vel = comps.velocity
        local hp  = comps.health
        if pos and vel then
            local x = pos.x + vel.x * dt
            local y = pos.y + vel.y * dt
            if x < 0 then x = 0; vel.x = -vel.x
            elseif x > bound then x = bound; vel.x = -vel.x end
            if y < 0 then y = 0; vel.y = -vel.y
            elseif y > bound then y = bound; vel.y = -vel.y end
            pos.x = x
            pos.y = y
        end
        if hp and hp.hp < hp.maxhp then
            hp.hp = hp.hp + 1
        end
    end
end

--- 遍历背包（低频 CRUD 的典型场景）
-- @return total_items, entity_count
function World:bag_total()
    local total, cnt = 0, 0
    for _, comps in pairs(self.comps) do
        local bag = comps.bag
        if bag then
            cnt = cnt + 1
            total = total + #bag.items
        end
    end
    return total, cnt
end

--- 给所有带 health 的实体扣血
function World:damage_all(dmg)
    for _, comps in pairs(self.comps) do
        local hp = comps.health
        if hp then
            hp.hp = hp.hp - dmg
            if hp.hp < 0 then hp.hp = 0 end
        end
    end
end

return M
