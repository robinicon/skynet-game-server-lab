-- test_schema.lua — schema registry 完整性、类型约束、op 映射

local skynet   = require "skynet"
local schema   = require "shared.schema"
local testutil = require "shared.testutil"

local M = {}

function M.run()
    local t = testutil.new("test_schema")

    local nf, na = 0, 0
    for _ in pairs(schema.fields.by_id) do nf = nf + 1 end
    for _ in pairs(schema.actions.by_aid) do na = na + 1 end
    t.eq(nf, 13, "field count")
    t.check(na >= 15, "action count at least 15 (got " .. na .. ")")
    t.eq(schema.op_of(15), "u.missionClaimReward", "action 15 still present")
    t.eq(schema.op_of(16), "u.crossSubmit", "P0.5 action 16 crossSubmit")
    t.eq(schema.op_of(17), "u.crossRank", "P0.5 action 17 crossRank")
    t.eq(schema.fields.version, 1, "schema version")

    local seen = {}
    local unique = true
    for fid, f in pairs(schema.fields.by_id) do
        if seen[fid] or schema.fields.by_name[f.name] ~= fid then unique = false end
        seen[fid] = true
    end
    t.check(unique, "fid <-> name bijection")

    t.eq(schema.fid("gold"), 4, "gold fid")
    t.eq(schema.partition_of("heroes"), "hero", "heroes partition")

    local state = {}
    t.check(schema.set(state, "level", 2), "set level")
    t.eq(schema.get(state, "level"), 2, "get level")
    t.eq(state[3], 2, "state keyed by fid")

    local ok, err = schema.set(state, "level", "2")
    t.check(not ok and err:match("expects int"), "type check rejects string for int")
    local ok2 = schema.set(state, "not_exist", 1)
    t.check(not ok2, "unknown field rejected")

    local hero = schema.resolve_op("u.heroUpdateLvAuto")
    t.check(hero ~= nil and hero.aid == 10, "hero op resolves to aid 10")
    t.eq(hero.params[2], "auto", "action param schema")
    t.check(schema.action(999) == nil, "unknown aid returns nil")
    t.eq(schema.op_of(5), "u.avatar_info", "aid to op")

    local base = schema.snapshot({ [1] = 42, [3] = 7 }, "base")
    t.eq(base[1], 42, "partition snapshot keeps fid keys")
    t.eq(base[6], nil, "partition snapshot excludes other partitions")

    local e = schema.errors
    t.eq(e.OK, 200, "OK code")
    t.eq(e.BAD_PASSWORD, -3, "BAD_PASSWORD code")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
