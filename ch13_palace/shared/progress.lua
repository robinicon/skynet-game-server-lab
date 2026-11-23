-- shared/progress.lua — U4 运行时进度态的读写工具
--
-- 进度态塞在现有 activity map（fid 9）里，不新增 schema field（见 U4_DEVLOG §3.1）。
-- 布局：
--   activity.stage   = { clearMax=, exp= }
--   activity.fight   = { last={ stageId=, seed=, power=, needPower=, win= } }
--   activity.reward  = { signDay=, onlineMin=, onlineClaimed={ [minutes]=true } }
--   activity.shop    = { bought={ [goodsId]=count } }
--
-- handler 契约：不改入参状态，所有写操作返回新表供 changes 使用（与 baglib 一致）。
-- 子键一律用字符串（"stage" 等），避免 JSON 往返把数字字符串键转成 number。

local json = require "shared.json"

local M = {}

local function deep_copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deep_copy(x) end
    -- 保住 json.object 标记：否则"先打标、再 with_section 拷贝"会把形状标记丢掉，
    -- 数字键 map 又会退回按 is_array 判定（同一结构随数据换形状）。
    local mt = getmetatable(v)
    if mt and mt.__json_object then setmetatable(out, mt) end
    return out
end

M.deep_copy = deep_copy

-- 取 activity 里的某个子表（不存在返回空表，不共享引用）
function M.section(activity, name)
    local s = activity and activity[name]
    if type(s) ~= "table" then return {} end
    return deep_copy(s)
end

-- 把子表写回 activity，返回新的 activity 表
function M.with_section(activity, name, section)
    local out = deep_copy(activity or {})
    out[name] = section
    return out
end

-- 数字键映射（claimed / bought / onlineClaimed）显式按 object 编码。
-- 原因：json.is_array 的判定依赖"键是否恰好是 1..n 连续"，
-- {[1]=true} 会被编成 [true]、{[1]=true,[3]=true} 会被编成 {"1":true,"3":true}——
-- 同一逻辑结构随数据长度换形状，落盘快照与对账断言都无法稳定复现。
function M.as_object(map)
    return json.object(map or {})
end

-- 数字键规范化：JSON 解码会把 "101" 还原成 number，写入时统一用 number
local function nkey(id)
    return tonumber(id) or id
end

-- 子表里数字键计数 +delta，返回新子表
function M.bump_count(section, field, id, delta)
    local out = deep_copy(section or {})
    out[field] = out[field] or {}
    local k = nkey(id)
    local left = (out[field][k] or 0) + (delta or 0)
    if left <= 0 then out[field][k] = nil else out[field][k] = left end
    if not next(out[field]) then out[field] = nil end
    return out
end

return M
