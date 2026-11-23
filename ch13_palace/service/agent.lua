-- service/agent.lua — 会话态 + ACTION_REQ 分发
--
-- 约定：aid 的含义查 schema，不写 if op == "u.xxx"；业务只操作 schema 字段。

local skynet  = require "skynet"
local schema  = require "shared.schema"
local message = require "shared.message"

local CMD = {}
local db
local uid = 0
local suspended = false   -- 阶段 3：断线挂起态，超时后落盘退出
local subscribed = {}     -- 阶段 4：on_demand 分区订阅表
local wire = 1            -- 阶段 4：1=legacy（默认），2=新 wire 协议
local hub = nil           -- P0.5：跨服中心地址，由 main 注入；未注入时 cross handler 返回明确错误

local function set_fields(changes)
    local ok, res = skynet.call(db, "lua", "set_fields", uid, changes)
    if not ok then error(res) end
    return res
end

-- 阶段 5：处理制注册。一个领域一个模块，schema 的 handler 列决定路由，
-- 迁移新批次只需新增 service/handler/<domain>.lua + 导表加 action，不再改本文件。
local handler_cache = {}

local function load_handler(name)
    if handler_cache[name] == nil then
        local ok, mod = pcall(require, "handler." .. tostring(name))
        if ok and type(mod) == "table" and type(mod.handle) == "function" then
            handler_cache[name] = mod
        else
            handler_cache[name] = false
            skynet.error("[agent] cannot load handler module: " .. tostring(name) .. " (" .. tostring(mod) .. ")")
        end
    end
    return handler_cache[name] or nil
end

-- handler 只能通过 ctx 读状态、提交变更；不直接碰 state 与 db
local function make_ctx(state)
    local ctx = { rev = state.__rev or 0 }
    function ctx.get(name)
        local fid = schema.fid(name)
        if not fid then return nil end
        return state[fid]
    end
    function ctx.set_fields(changes)
        return set_fields(changes)
    end
    function ctx.uid()
        return uid
    end
    -- P0.5：跨服务调用统一走注入的 hub 地址，handler 不持有服务地址常量。
    -- 未注入时返回 nil, reason，由 cross handler 转成可读的业务错误。
    function ctx.call_hub(cmd, ...)
        if not hub then return nil, "hub_not_injected" end
        local ok, res = pcall(skynet.call, hub, "lua", cmd, ...)
        if not ok then return nil, "hub_call_failed: " .. tostring(res) end
        return res
    end
    return ctx
end

local function action_res(env, err_code, result, delta)
    return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid,
             err = err_code, result = result or {}, delta = delta }
end

local function handle_action(env)
    local action, err = schema.action(env.aid)
    if not action then
        return action_res(env, schema.errors.UNKNOWN_OP, { ok = false, reason = err })
    end

    local mod = load_handler(action.handler)
    if not mod then
        return action_res(env, schema.errors.UNKNOWN_OP,
            { ok = false, reason = "no handler module: " .. tostring(action.handler) })
    end

    local state = skynet.call(db, "lua", "load", uid)
    if not state then
        return action_res(env, schema.errors.BAD_STATE, { ok = false, reason = "entity not loaded" })
    end

    local ok, out = pcall(mod.handle, make_ctx(state), action, env.params or {})
    if not ok then
        skynet.error("[agent] handler crash " .. tostring(action.op) .. ": " .. tostring(out))
        return action_res(env, schema.errors.BAD_STATE, { ok = false, reason = "handler crash" })
    end
    if type(out) ~= "table" then
        return action_res(env, schema.errors.BAD_STATE, { ok = false, reason = "handler returned non-table" })
    end

    local changes = out.changes
    local rev = state.__rev or 0
    local delta
    if changes and next(changes) then
        local res = set_fields(changes)
        rev = res.rev
        local d, derr = message.make_delta(rev - 1, rev, changes, env.seq)
        if not d then
            skynet.error("[agent] delta build failed: " .. tostring(derr))
        else
            delta = d
        end
    end

    local result = out.result or {}
    if result.rev == nil then result.rev = rev end
    return action_res(env, out.err or schema.errors.OK, result, delta)
end

function CMD.init(db_addr, owner_uid)
    db = db_addr
    uid = owner_uid or 0
    return true
end

-- 阶段 4：网关在首包鉴权后协商 wire 版本（1=legacy 全量，2=策略过滤 + 独立 delta）
function CMD.set_wire(v)
    wire = (tonumber(v) == 2) and 2 or 1
    return wire
end

function CMD.bind(owner_uid)
    uid = owner_uid
    return true
end

-- P0.5：注入跨服中心地址（main 启动时调用）
function CMD.set_hub(hub_addr)
    hub = hub_addr
    return true
end

-- 阶段 4：wire 控制动作（aid=6..9），由 schema 的 handler="wire" 路由到这里
local function handle_wire(env)
    local action = schema.action(env.aid)
    local op = action and action.op or ""
    local params = env.params or {}

    if op == "u.subscribe" then
        local parts = params.partitions or {}
        for _, name in ipairs(parts) do
            if schema.partition(name) then subscribed[name] = true end
        end
        return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid,
                 err = schema.errors.OK,
                 result = { ok = true, wire = wire, subscribed = subscribed } }

    elseif op == "u.unsubscribe" then
        local parts = params.partitions or {}
        for _, name in ipairs(parts) do subscribed[name] = nil end
        return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid,
                 err = schema.errors.OK,
                 result = { ok = true, wire = wire, subscribed = subscribed } }

    elseif op == "u.snapshot" then
        -- 客户端主动拉取：按策略（或指定分区）重建快照
        local state = skynet.call(db, "lua", "load", uid)
        if not state then
            return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid,
                     err = schema.errors.BAD_STATE, result = { ok = false } }
        end
        local parts = params.partitions or {}
        local partitions
        if #parts > 0 then
            partitions = {}
            for _, name in ipairs(parts) do
                local one = schema.snapshot(state, name)
                if one and next(one) then partitions[name] = one end
            end
        else
            partitions = schema.snapshot_by_policy(state, subscribed)
        end
        return { kind = message.KIND.SNAPSHOT, seq = env.seq, rev = state.__rev,
                 partitions = partitions }

    elseif op == "u.delta" then
        -- 追帧：客户端 base_rev 落后时，从当前状态生成一次合并增量（只含允许下发的 fid）
        local state = skynet.call(db, "lua", "load", uid)
        local cur_rev = (state and state.__rev) or 0
        local base_rev = tonumber(params.base_rev) or 0
        if base_rev >= cur_rev then
            return { kind = message.KIND.DELTA, seq = env.seq, base_rev = cur_rev,
                     rev = cur_rev, mask = {}, values = {} }
        end
        local changes = {}
        for _, f in pairs(schema.fields.by_id) do
            if schema.delta_allowed(f.fid, subscribed) and state[f.fid] ~= nil then
                changes[f.name] = state[f.fid]
            end
        end
        local delta = message.make_delta(base_rev, cur_rev, changes, env.seq)
        return delta
    end

    return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid,
             err = schema.errors.UNKNOWN_OP, result = { ok = false, reason = "no wire handler" } }
end

function CMD.dispatch(env)
    if env.kind == message.KIND.ACTION_REQ then
        local action = schema.action(env.aid)
        if action and action.handler == "wire" then
            return handle_wire(env)
        end
        return handle_action(env)
    elseif env.kind == message.KIND.PING then
        return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = 0,
                 err = schema.errors.OK, result = { ok = true } }
    end
    return { kind = message.KIND.ACTION_RES, seq = env.seq, aid = env.aid or 0,
             err = schema.errors.BAD_STATE, result = { ok = false, reason = "unsupported kind" } }
end

function CMD.snapshot()
    local state = skynet.call(db, "lua", "load", uid)
    if not state then return nil end
    local partitions
    if wire >= 2 then
        partitions = schema.snapshot_by_policy(state, subscribed)
    else
        partitions = {}
        for name in pairs(schema.fields.partitions) do
            partitions[name] = schema.snapshot(state, name)
        end
    end
    return { kind = message.KIND.SNAPSHOT, seq = 0, rev = state.__rev, partitions = partitions }
end

function CMD.state()
    return skynet.call(db, "lua", "load", uid)
end

-- 阶段 5：迁移清单 —— schema 里每个 action 落到哪个 handler 模块，供对账脚本核对
function CMD.manifest()
    local by_handler, actions = {}, {}
    for aid, a in pairs(schema.actions.by_aid) do
        by_handler[a.handler] = by_handler[a.handler] or {}
        table.insert(by_handler[a.handler], a.op)
        actions[#actions + 1] = { aid = aid, op = a.op, handler = a.handler }
    end
    for _, list in pairs(by_handler) do table.sort(list) end
    table.sort(actions, function(x, y) return x.aid < y.aid end)
    return { by_handler = by_handler, actions = actions,
             loaded = (function()
                 local out = {}
                 for name, mod in pairs(handler_cache) do out[name] = mod and true or false end
                 return out
             end)() }
end

-- ========== 阶段 3：会话生命周期 ==========

-- 断线：不销毁实体、不退出，只标记挂起，等待网关的重连窗口
function CMD.suspend()
    suspended = true
    return true
end

-- 重连：恢复为活动态，并把当前快照回给网关（网关对齐本次 session 后下发）
function CMD.resume(fd)
    suspended = false
    return CMD.snapshot(), fd
end

function CMD.is_suspended()
    return suspended
end

-- 超时未重连：把脏分区落盘，返回写入清单供网关记录审计；网关随后发 shutdown
function CMD.expire()
    if not suspended then
        return { ok = false, reason = "not suspended", written = {} }
    end
    local ok, res = skynet.call(db, "lua", "save", uid)
    local written = (type(res) == "table" and res.written) or {}
    return {
        ok = ok,
        written = written,
        rev = (type(res) == "table" and res.rev) or 0,
    }
end

function CMD.shutdown()
    suspended = false
    skynet.exit()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "agent: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function() end)
