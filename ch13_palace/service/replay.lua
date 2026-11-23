-- service/replay.lua — 离线回放器（对账用，不参与线上链路）
--
-- 由 main.lua 在 CH13_REPLAY_FILE 存在时启动：
--   读取样本 JSON（cases[].seed/op/params），逐条在干净实体上执行，
--   把 err / result / 指定字段的落地状态写成 CH13_REPLAY_OUT，供 compare_with_java.py 比对。
--
-- 样本里的 expect 只描述「必须成立的部分」：result 做子集比较，state 用点名路径。

local skynet  = require "skynet"
local json    = require "shared.json"
local schema  = require "shared.schema"
local message = require "shared.message"

local CMD = {}

local function read_file(path)
    local f = assert(io.open(path, "r"), "replay: cannot open " .. tostring(path))
    local text = f:read("*a")
    f:close()
    return text
end

-- 只取 schema 里声明的字段，按字段名输出，避免把 __rev 之类的内部键带出去
local function capture_state(state)
    local out = {}
    for name, fid in pairs(schema.fields.by_name) do
        out[name] = state[fid]
    end
    out["__rev"] = state.__rev
    return out
end

-- U2：把 seed 变成客户端能直接喂给 Session 的初始 SNAPSHOT。
-- 只在 CH13_REPLAY_WIRE_OUT 开启时生成——默认对账输出一个字节都不变。
local function seed_snapshot(state, rev)
    -- 按服务端快照口径从**播种后的完整实体**取字段（而不是只取 seed 里写了的键）：
    -- db 会给 gold/silver 等字段默认值 0，真快照也会带它们；少了它们，
    -- 客户端回放"失败路径 state.gold==0"会被误判成字段缺失。
    local partitions = {}
    for fid, f in pairs(schema.fields.by_id) do
        if f.replicate ~= "none" and state and state[fid] ~= nil then
            local pname = f.partition
            partitions[pname] = partitions[pname] or {}
            partitions[pname][fid] = state[fid]
        end
    end
    -- fid 1..n 连续时必须显式打对象标记，否则 json 会编码成数组，客户端展平拿不到键
    -- （这正是 P0 修过的那个 bug，回放夹具也不能再踩一次）
    for name, part in pairs(partitions) do partitions[name] = json.object(part) end
    return { kind = message.KIND.SNAPSHOT, seq = 0, rev = rev, partitions = partitions }
end

-- U2：按 wire=2 的网关口径拆分 out（ACTION_RES 不带 delta，DELTA 独立成帧）。
-- 这样客户端回放走的是**真实服务端产生的帧**，而不是在 C# 里复刻一遍规则。
local function wire_frames(out)
    local frames = {
        { kind = message.KIND.ACTION_RES, seq = out.seq, aid = out.aid,
          err = out.err, result = out.result },
    }
    if out.delta then frames[#frames + 1] = out.delta end
    return frames
end

-- 一条用例：干净实体 → 播种 → 执行 → 采集
local function run_case(db, idx, case, seq, with_wire, hub)
    skynet.call(db, "lua", "reset")
    local acct = string.format("replay_%d@test", idx)
    local _, uid = skynet.call(db, "lua", "create_account", acct, "salt", "hash")
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, acct, uid)

    if case.seed then
        local ok, err = skynet.call(db, "lua", "set_fields", euid, case.seed)
        if not ok then
            return { name = case.name, op = case.op, err = -1,
                     reason = "seed failed: " .. tostring(err) }
        end
    end

    local pre_state = with_wire and skynet.call(db, "lua", "load", euid) or nil

    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", db, euid)
    -- P0.5：跨服/本服榜类动作要 hub，回放也要有，否则只能回放出 hub_unavailable
    if hub then skynet.call(agent, "lua", "set_hub", hub) end

    local env = message.normalize_in({ id = seq, op = case.op, params = case.params or {} })
    local out
    if not env then
        out = { err = schema.errors.UNKNOWN_OP, result = { ok = false, reason = "unknown op" } }
    else
        out = skynet.call(agent, "lua", "dispatch", env)
    end

    local state = skynet.call(db, "lua", "load", euid)
    -- agent 收到 shutdown 会自行 skynet.exit，不能 call（回复永远不来）
    skynet.send(agent, "lua", "shutdown")

    local captured = capture_state(state or {})
    local record = {
        name = case.name,
        op = case.op,
        err = out.err,
        reason = out.result and out.result.reason,
        result = out.result,
        state = captured,
    }
    if with_wire then
        record.wire = {
            seed = case.seed or {},
            aid = env and env.aid or 0,
            params = case.params or {},
            expect = case.expect or {},       -- 与 make reconcile 用同一份期望
            -- 增量 base_rev 就是动作前的 rev；失败用例没有 delta，用播种后的 rev。
            snapshot = seed_snapshot(pre_state,
                (out.delta and out.delta.base_rev) or (pre_state and pre_state.__rev) or 0),
            frames = wire_frames(out),
            serverState = captured,
        }
    end
    return record
end

function CMD.run(db, hub)
    local in_path = os.getenv("CH13_REPLAY_FILE")
    local out_path = os.getenv("CH13_REPLAY_OUT") or "data/replay_out.json"
    if not in_path or in_path == "" then
        skynet.error("[replay] CH13_REPLAY_FILE not set")
        return { ok = false, reason = "no input" }
    end

    local doc = json.decode(read_file(in_path))
    if not doc then
        skynet.error("[replay] bad json: " .. in_path)
        return { ok = false, reason = "bad json" }
    end

    local wire_out = os.getenv("CH13_REPLAY_WIRE_OUT")
    local results = { batch = doc.batch or "", cases = {} }
    for idx, case in ipairs(doc.cases or {}) do
        results.cases[#results.cases + 1] = run_case(db, idx, case, 100 + idx, wire_out ~= nil and wire_out ~= "", hub)
    end

    local function write_json(path, doc_out)
        local dir = path:match("^(.*)/[^/]+$")
        if dir then os.execute("mkdir -p " .. dir) end
        local fh = assert(io.open(path, "w"), "replay: cannot write " .. path)
        fh:write(json.encode(doc_out))
        fh:close()
    end

    write_json(out_path, results)
    if wire_out and wire_out ~= "" then write_json(wire_out, results) end

    skynet.error(string.format("[replay] %s: %d cases -> %s", results.batch, #results.cases, out_path))
    return { ok = true, cases = #results.cases, out = out_path, wire = wire_out }
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "replay: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function() end)

return CMD
