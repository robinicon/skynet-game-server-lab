-- shared/schema.lua — schema registry 运行时访问层
--
-- 数据本身只有 fid；字段名、类型、分区、持久化策略全部来自 conf/schema.json 生成物。
-- 业务代码通过 schema.get/set 访问，禁止直接写 state[数字键]。

local fields  = require "generated.fields_generated"
local actions = require "generated.actions_generated"
local errors  = require "generated.errors_generated"

local M = {
    fields  = fields,
    actions = actions,
    errors  = errors,
}

local checkers = {
    int    = function(v) return type(v) == "number" and v % 1 == 0 end,
    number = function(v) return type(v) == "number" end,
    string = function(v) return type(v) == "string" end,
    bool   = function(v) return type(v) == "boolean" end,
    map    = function(v) return type(v) == "table" end,
    array  = function(v) return type(v) == "table" end,
}

function M.field(name)
    local fid = fields.by_name[name]
    if not fid then return nil, "unknown field: " .. tostring(name) end
    return fields.by_id[fid]
end

function M.fid(name)
    local f = M.field(name)
    return f and f.fid or nil
end

function M.get(state, name)
    local fid = M.fid(name)
    if not fid then error("schema.get: unknown field " .. tostring(name)) end
    return state[fid]
end

function M.set(state, name, value)
    local f, err = M.field(name)
    if not f then return false, err end
    if not checkers[f.type](value) then
        return false, string.format("field %s expects %s, got %s", name, f.type, type(value))
    end
    state[f.fid] = value
    return true
end

function M.partition(name)
    return fields.partitions[name]
end

function M.partition_of(name)
    local f = M.field(name)
    return f and f.partition or nil
end

function M.snapshot(state, partition_name)
    local fids = fields.partitions[partition_name]
    if not fids then return nil, "unknown partition: " .. tostring(partition_name) end
    local out = {}
    for _, fid in ipairs(fids) do
        if state[fid] ~= nil then out[fid] = state[fid] end
    end
    return out
end

-- 阶段 4：按 replicate 策略过滤字段。
--   snapshot / delta —— 默认随初始快照下发
--   on_demand        —— 仅订阅该分区后下发
--   none             —— 永不下发
-- 返回 { [partition] = { [fid]=value } }，空分区不出现。
function M.snapshot_by_policy(state, subscribed)
    subscribed = subscribed or {}
    local partitions = {}
    for pname, fids in pairs(fields.partitions) do
        local out = {}
        for _, fid in ipairs(fids) do
            local f = fields.by_id[fid]
            local rep = f and f.replicate or "none"
            local include = (rep == "snapshot" or rep == "delta")
            if rep == "on_demand" and subscribed[pname] then include = true end
            if include and state[fid] ~= nil then out[fid] = state[fid] end
        end
        if next(out) then partitions[pname] = out end
    end
    return partitions
end

-- 阶段 4：某字段是否允许通过 delta 下发（on_demand 未订阅则不下发）
function M.delta_allowed(fid, subscribed)
    subscribed = subscribed or {}
    local f = fields.by_id[fid]
    if not f then return false end
    local rep = f.replicate
    if rep == "snapshot" or rep == "delta" then return true end
    if rep == "on_demand" then return subscribed[f.partition] == true end
    return false  -- none
end

function M.resolve_op(op)
    local aid = actions.by_op[op]
    if not aid then return nil, "unknown op: " .. tostring(op) end
    return actions.by_aid[aid]
end

function M.action(aid)
    return actions.by_aid[aid], (actions.by_aid[aid] and nil or "unknown aid: " .. tostring(aid))
end

function M.op_of(aid)
    local a = actions.by_aid[aid]
    return a and a.op or nil
end

return M
