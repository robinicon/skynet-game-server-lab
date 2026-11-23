-- shared/bag.lua — 背包（道具模板 id -> 数量）的纯函数工具
--
-- 背包是 map 字段，值为 { ["1001"] = 3 }。所有修改都返回新表，
-- handler 只把新表放进 changes，不直接改状态（保证 delta 与落盘一致）。

local M = {}

-- 键规范化：数字 id 用数字键。
-- 原因：shared/json.lua 解码时会把 "^%d+$" 的键还原成 number，若这里用字符串键，
-- 落盘再读回（或过线再解码）就会查不到同一个道具。
local function key(id)
    local n = tonumber(id)
    return n or tostring(id)
end

function M.copy(bag)
    local out = {}
    for k, v in pairs(bag or {}) do out[k] = v end
    return out
end

function M.count(bag, id)
    return (bag and bag[key(id)]) or 0
end

function M.set(bag, id, n)
    local out = M.copy(bag)
    if n and n > 0 then out[key(id)] = n else out[key(id)] = nil end
    return out
end

function M.add(bag, id, n)
    return M.set(bag, id, M.count(bag, id) + (n or 0))
end

-- 批量加：items = { {templateId=, count=}, ... }
function M.add_many(bag, items)
    local out = M.copy(bag)
    for _, it in ipairs(items or {}) do
        out[key(it.templateId)] = (out[key(it.templateId)] or 0) + it.count
        if out[key(it.templateId)] <= 0 then out[key(it.templateId)] = nil end
    end
    return out
end

-- 是否够扣：cost = { ["1001"] = 2 }
function M.has(bag, cost)
    for id, n in pairs(cost or {}) do
        if M.count(bag, id) < n then return false, id end
    end
    return true
end

-- 扣减，返回新背包；不足时返回 nil, 缺失的 id
function M.consume(bag, cost)
    local out = M.copy(bag)
    for id, n in pairs(cost or {}) do
        local left = (out[key(id)] or 0) - n
        if left < 0 then return nil, id end
        if left == 0 then out[key(id)] = nil else out[key(id)] = left end
    end
    return out
end

function M.total(bag)
    local n = 0
    for _, v in pairs(bag or {}) do n = n + v end
    return n
end

return M
