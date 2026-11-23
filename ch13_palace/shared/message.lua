-- shared/message.lua — 抽象消息信封（7 种 kind）
--
-- 老协议：{ id, type, scope, op, error, params } 一帧一 op。
-- 内部统一：{ kind, seq, ... }，由 aid 查 schema 决定含义，params 按 schema 命名。

local json   = require "shared.json"
local schema = require "shared.schema"

local M = {}

M.KIND = {
    HELLO      = 1,
    ACTION_REQ = 2,
    ACTION_RES = 3,
    SNAPSHOT   = 4,
    DELTA      = 5,
    EVENT      = 6,
    PING       = 7,
}

M.KIND_NAME = {}
for name, code in pairs(M.KIND) do M.KIND_NAME[code] = name end

-- 出站形状固定：分区与 delta.values 一律按 fid 对象下发。
-- 否则 fid 1..n 连续时 json 会编码成数组 `[1000,"acc",1,0]`，
-- 客户端同一份代码要在“数组”和“对象”两种形状之间猜。
local function as_object(t)
    if type(t) ~= "table" then return t end
    return json.object(t)
end

local function shape_out(env)
    local kind = env.kind
    if kind == M.KIND.SNAPSHOT then
        local parts = {}
        for name, fields in pairs(env.partitions or {}) do
            parts[name] = as_object(fields)
        end
        local out = {}
        for k, v in pairs(env) do out[k] = v end
        out.partitions = parts
        return out
    elseif kind == M.KIND.DELTA then
        local out = {}
        for k, v in pairs(env) do out[k] = v end
        out.values = as_object(env.values or {})
        return out
    end
    return env
end

function M.encode(envelope)
    return json.encode(shape_out(envelope))
end

function M.decode(text)
    return json.decode(text)
end

-- 老协议入站 → 统一 ACTION_REQ；params 位置参数按 action schema 变成命名参数
function M.normalize_in(legacy)
    if type(legacy) ~= "table" then return nil, "legacy message must be table" end
    local action, err = schema.resolve_op(legacy.op)
    if not action then return nil, err end
    local raw = legacy.params or {}
    local params = {}
    for i, name in ipairs(action.params) do
        params[name] = raw[i]
    end
    return {
        kind   = M.KIND.ACTION_REQ,
        seq    = legacy.id,
        aid    = action.aid,
        params = params,
    }
end

-- 统一信封出站 → 老协议（客户端不改也能收到）
function M.to_legacy(envelope)
    local kind = envelope.kind
    if kind == M.KIND.ACTION_RES then
        return {
            id    = envelope.seq,
            type  = "r",
            scope = "c",
            op    = schema.op_of(envelope.aid) or "u.unknown",
            error = envelope.err or schema.errors.OK,
            params = envelope.result or {},
        }
    elseif kind == M.KIND.SNAPSHOT then
        return {
            id = envelope.seq, type = "p", scope = "c", op = "u.snapshot", error = schema.errors.OK,
            params = { rev = envelope.rev, partitions = envelope.partitions },
        }
    elseif kind == M.KIND.DELTA then
        return {
            id = envelope.seq, type = "p", scope = "c", op = "u.delta", error = schema.errors.OK,
            params = {
                base_rev = envelope.base_rev, rev = envelope.rev,
                mask = envelope.mask, values = envelope.values,
            },
        }
    elseif kind == M.KIND.EVENT then
        return {
            id = envelope.seq, type = "p", scope = "c", op = envelope.event or "u.event",
            error = schema.errors.OK, params = envelope.params or {},
        }
    end
    return nil, "cannot convert kind " .. tostring(kind)
end

-- 生成增量：changes 用字段名，落线只传 fid + 值
function M.make_delta(base_rev, rev, changes, seq)
    local mask, values = {}, {}
    for name, value in pairs(changes) do
        local fid, err = schema.fid(name)
        if not fid then return nil, err end
        mask[#mask + 1] = fid
        values[fid] = value
    end
    table.sort(mask)
    return {
        kind = M.KIND.DELTA, seq = seq, base_rev = base_rev, rev = rev,
        mask = mask, values = values,
    }
end

function M.apply_delta(state, delta)
    if delta.kind ~= M.KIND.DELTA then return false, "not a delta" end
    if (state.__rev or 0) >= delta.rev then return false, "stale delta" end
    for _, fid in ipairs(delta.mask) do
        state[fid] = delta.values[fid]
    end
    state.__rev = delta.rev
    return true
end

return M
