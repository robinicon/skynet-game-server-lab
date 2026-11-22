-- test/test_db.lua — DB 服务 CRUD 与连接池测试

local skynet = require "skynet"
local utils  = require "shared.utils"

local pass, fail = 0, 0
local out = {}

local function emit(s)
    out[#out + 1] = s
    io.write(s .. "\n")
end

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        emit(string.format("  PASS  %s", name))
    else
        fail = fail + 1
        emit(string.format("  FAIL  %s  %s", name, tostring(detail)))
    end
end

local handlers = {}

function handlers.run(db)
    pass, fail = 0, 0
    out = {}

    if not db then
        emit("ERROR: db addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR: no db" }
    end

    skynet.call(db, "lua", "reset")

    emit("=== D1: write then read ===")
    local ok1 = skynet.call(db, "lua", "save_sync", 1, { hp = 100, gold = 50 })
    check("D1.1 save_sync ok", ok1 == true, tostring(ok1))
    local row1 = skynet.call(db, "lua", "load", 1)
    check("D1.2 row exists", row1 ~= nil)
    check("D1.3 hp correct", row1 and row1.hp == 100, row1 and row1.hp)
    check("D1.4 gold correct", row1 and row1.gold == 50, row1 and row1.gold)
    check("D1.5 version incremented", row1 and row1.version == 1, row1 and row1.version)

    emit("=== D2: read non-existent returns nil (no error) ===")
    local row2 = skynet.call(db, "lua", "load", 99999)
    check("D2.1 nil for missing row", row2 == nil, tostring(row2))

    emit("=== D3: overwrite updates fields ===")
    skynet.call(db, "lua", "save_sync", 1, { hp = 88 })
    local row3 = skynet.call(db, "lua", "load", 1)
    check("D3.1 hp updated", row3 and row3.hp == 88, row3 and row3.hp)
    check("D3.2 gold preserved (partial update)", row3 and row3.gold == 50, row3 and row3.gold)
    check("D3.3 version=2", row3 and row3.version == 2, row3 and row3.version)

    emit("=== D4: delete ===")
    skynet.call(db, "lua", "delete", 1)
    local row4 = skynet.call(db, "lua", "load", 1)
    check("D4.1 deleted", row4 == nil, tostring(row4))

    emit("=== D5: agent save / load / exit ===")
    local agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "init", 2, db)
    skynet.call(agent, "lua", "modify", -30, 200)
    local st5 = skynet.call(agent, "lua", "get")
    check("D5.1 in-memory state", st5.hp == 70 and st5.gold == 200,
        string.format("hp=%s gold=%s", tostring(st5.hp), tostring(st5.gold)))
    local ok5 = skynet.call(agent, "lua", "save_sync")
    check("D5.2 save_sync ok", ok5 == true, tostring(ok5))
    local row5 = skynet.call(db, "lua", "load", 2)
    check("D5.3 persisted correctly", row5 and row5.hp == 70 and row5.gold == 200,
        row5 and string.format("hp=%s gold=%s", tostring(row5.hp), tostring(row5.gold)))

    -- 退出前同步存盘（design.md 的关键场景）
    skynet.call(agent, "lua", "modify", -10, 0)
    local ok5e = skynet.call(agent, "lua", "exit")
    check("D5.4 exit saved", ok5e == true, tostring(ok5e))
    local row5e = skynet.call(db, "lua", "load", 2)
    check("D5.5 final state persisted (hp=60)", row5e and row5e.hp == 60, row5e and row5e.hp)

    emit("=== D6: connection pool basics ===")
    local st6 = skynet.call(db, "lua", "stats")
    -- driver 应与当前配置一致（memory 默认；CH7_DB_DRIVER=mysql 时为 mysql）
    local expect_driver = os.getenv("CH7_DB_DRIVER") or "memory"
    check("D6.1 driver matches config", st6.driver == expect_driver,
        string.format("got=%s expected=%s", tostring(st6.driver), expect_driver))
    check("D6.2 pool total >= min", st6.pool.total >= st6.pool.min,
        string.format("total=%d min=%d", st6.pool.total, st6.pool.min))
    check("D6.3 no leaked waiters", st6.pool.waiting == 0, st6.pool.waiting)

    emit("=== D7: many sequential ops — no connection leak ===")
    for i = 1, 100 do
        skynet.call(db, "lua", "save_sync", 10, { hp = i })
    end
    local st7 = skynet.call(db, "lua", "stats")
    check("D7.1 pool not grown beyond max for serial load",
        st7.pool.total <= st7.pool.max,
        string.format("total=%d max=%d", st7.pool.total, st7.pool.max))
    check("D7.2 all connections returned", st7.pool.free + st7.pool.waiting >= 1,
        string.format("free=%d waiting=%d", st7.pool.free, st7.pool.waiting))
    local row7 = skynet.call(db, "lua", "load", 10)
    check("D7.3 last write persisted", row7 and row7.hp == 100, row7 and row7.hp)

    emit("=== D8: stats interface ===")
    local need = { "driver", "no_queue", "pool", "queues" }
    local miss = {}
    for _, k in ipairs(need) do
        if st7[k] == nil then miss[#miss + 1] = k end
    end
    check("D8.1 stats fields complete", #miss == 0, table.concat(miss, ","))
    check("D8.2 one queue per uid", st7.queues >= 2, st7.queues)

    emit(string.format("\n  Subtotal: %d PASS, %d FAIL", pass, fail))
    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_db", handlers)

return handlers
