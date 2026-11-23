-- test_message.lua — 老协议归一化、7 种信封、delta 编解码

local skynet   = require "skynet"
local schema   = require "shared.schema"
local message  = require "shared.message"
local json     = require "shared.json"
local testutil = require "shared.testutil"

local M = {}

function M.run()
    local t = testutil.new("test_message")

    local count = 0
    for _ in pairs(message.KIND) do count = count + 1 end
    t.eq(count, 7, "seven envelope kinds")

    local env, err = message.normalize_in({
        id = 7, type = "r", scope = "c", op = "u.heroUpdateLvAuto",
        params = { "hero-1", true },
    })
    t.check(env ~= nil, "normalize legacy message: " .. tostring(err))
    t.eq(env.kind, message.KIND.ACTION_REQ, "normalized kind")
    t.eq(env.aid, 10, "normalized aid from config")
    t.eq(env.seq, 7, "seq preserved")
    t.eq(env.params.heroId, "hero-1", "positional param named by schema")
    t.eq(env.params.auto, true, "second param named by schema")

    local bad = message.normalize_in({ op = "u.noSuchOp", params = {} })
    t.check(bad == nil, "unknown op rejected")

    local res = { kind = message.KIND.ACTION_RES, seq = 7, aid = 10,
                  err = schema.errors.OK, result = { true } }
    local legacy = message.to_legacy(res)
    t.eq(legacy.op, "u.heroUpdateLvAuto", "response op restored")
    t.eq(legacy.error, 200, "response error code")
    t.eq(legacy.id, 7, "response seq restored")

    local delta = message.make_delta(4, 5, { level = 2, gold = 50 }, 9)
    t.eq(delta.kind, message.KIND.DELTA, "delta kind")
    t.eq(delta.base_rev, 4, "delta base rev")
    t.eq(#delta.mask, 2, "delta mask size")
    t.eq(delta.mask[1], schema.fid("level"), "mask is sorted fid list")
    t.eq(delta.values[schema.fid("gold")], 50, "delta values keyed by fid")

    local state = { [schema.fid("level")] = 1, __rev = 4 }
    t.check(message.apply_delta(state, delta), "apply delta")
    t.eq(state[schema.fid("level")], 2, "delta updates field")
    t.eq(state.__rev, 5, "delta updates rev")
    t.check(not message.apply_delta(state, delta), "stale delta rejected")

    local text = message.encode(delta)
    local decoded = json.decode(text)
    t.eq(decoded.values[tostring(schema.fid("gold"))], nil, "string fid key absent")
    t.check(decoded.values[schema.fid("gold")] ~= nil or decoded.values[tostring(schema.fid("gold"))] ~= nil,
        "delta decodes to a fid-keyed table")

    local snap_legacy = message.to_legacy({ kind = message.KIND.SNAPSHOT, seq = 1, rev = 5,
        partitions = { base = { [1] = 9 } } })
    t.eq(snap_legacy.op, "u.snapshot", "snapshot maps to legacy push op")

    -- ===== 出站形状守卫（P0 修的两个真缺陷）=====
    -- 1) 稀疏 fid 表不能退化成数组：`{[1]=a,[3]=b}` 的 `#t` 是未定义边界，
    --    早期实现按 `#t > 0` 判定，会把 t[3] 静默丢掉。
    t.eq(json.encode({ [1] = "a", [3] = "b" }), '{"1":"a","3":"b"}',
        "sparse numeric keys encode as object (no key loss)")
    t.eq(json.encode({ [1] = "a", [2] = "b" }), '["a","b"]',
        "dense 1..n still encodes as array")

    -- 2) 分区必须始终是 fid 对象：fid 1..4 连续时若编码成数组，
    --    客户端就要在两种形状之间猜。json.object 显式打标强制 object。
    local snap_env = { kind = message.KIND.SNAPSHOT, seq = 1, rev = 1,
        partitions = { base = { [1] = 1000, [2] = "acc", [3] = 1, [4] = 0 } } }
    local snap_out = json.decode(message.encode(snap_env))
    t.check(type(snap_out.partitions.base) == "table", "snapshot base is a table")
    t.eq(snap_out.partitions.base[2], "acc",
        "snapshot base stays fid-keyed object even when fids are contiguous")
    t.eq(snap_out.partitions.base[1], 1000, "snapshot base keeps fid 1")

    -- 3) delta.values 同理，且 mask 必须仍是数组
    local d_env = message.make_delta(1, 2, { bag = { [1001] = 2 } }, 3)
    local d_out = json.decode(message.encode(d_env))
    t.check(type(d_out.mask) == "table" and #d_out.mask == 1, "delta mask stays an array")
    t.eq(d_out.values[schema.fid("bag")][1001], 2,
        "delta values stays fid-keyed object")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
