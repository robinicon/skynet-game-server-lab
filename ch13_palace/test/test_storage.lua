-- test_storage.lua — 分区写入、rev、脏标记、JSON 快照往返

local skynet   = require "skynet"
local schema   = require "shared.schema"
local json     = require "shared.json"
local testutil = require "shared.testutil"

local M = {}

local function has(list, name)
    for _, v in ipairs(list or {}) do if v == name then return true end end
    return false
end

function M.run(db)
    local t = testutil.new("test_storage")

    local uid = skynet.call(db, "lua", "create_entity", "avatar", 0, "storage@test")
    t.check(uid > 0, "create entity")
    local state = skynet.call(db, "lua", "load", uid)
    t.eq(schema.get(state, "account"), "storage@test", "account stored as field")
    t.eq(schema.get(state, "level"), 1, "default level")
    t.eq(state.__rev, 1, "initial rev")

    local ok, res = skynet.call(db, "lua", "set_fields", uid, { gold = 100 })
    t.check(ok, "set gold")
    t.eq(res.rev, 2, "rev increments")
    t.eq(#res.written, 1, "only one partition dirty")
    t.check(has(res.written, "base"), "base partition written")

    local ok2, res2 = skynet.call(db, "lua", "set_fields", uid, { heroes = { h1 = 3 } })
    t.check(ok2, "set heroes")
    t.check(has(res2.written, "hero"), "hero partition written")
    t.check(not has(res2.written, "base"), "base not rewritten on hero change")

    local ok3, saved = skynet.call(db, "lua", "save", uid)
    t.check(ok3, "save")
    t.check(has(saved.written, "base") and has(saved.written, "hero"), "dirty partitions saved")

    local ok4, saved2 = skynet.call(db, "lua", "save", uid)
    t.check(ok4 and #saved2.written == 0, "clean entity writes nothing")

    state = skynet.call(db, "lua", "load", uid)
    t.eq(schema.get(state, "gold"), 100, "gold persisted in memory")
    t.eq(schema.get(state, "heroes").h1, 3, "heroes persisted in memory")

    local ok5 = skynet.call(db, "lua", "flush")
    t.check(ok5, "flush snapshot")
    local f = io.open("data/test-snapshot.json", "r")
    t.check(f ~= nil, "snapshot file exists")
    if f then
        local text = f:read("*a")
        f:close()
        local doc = json.decode(text)
        t.check(doc ~= nil and doc.entities ~= nil, "snapshot decodes")
        local e = doc.entities[uid]
        t.check(e ~= nil and e.partitions ~= nil, "snapshot has entity partitions")
        local fid = schema.fid("gold")
        t.eq(e.partitions.base.data[fid], 100, "fid keys survive JSON round-trip")
    end

    local stats = skynet.call(db, "lua", "stats")
    t.check(stats.entities >= 1, "stats entity count")

    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
