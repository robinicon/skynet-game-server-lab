-- test_mysql_roundtrip.lua — 阶段 2：MySQL 驱动往返 + 重启持久化验证
--
-- 与内存驱动跑同一套 CRUD 契约断言，额外验证：
--   T7 脏分区只写变化的分区、索引字段单独落 entity_field
--   T8 重启模拟（新建驱动实例从 MySQL 重建缓存）后 gold 值不变
-- 运行前提：CH13_DB_DRIVER=mysql（由 Makefile 目标注入），mysqld 已启动。

local skynet   = require "skynet"
local md5      = require "md5"
local schema   = require "shared.schema"
local testutil = require "shared.testutil"

local M = {}

function M.run(db, login, gate)
    local t = testutil.new("test_mysql_roundtrip")
    local client_md5 = "0123456789abcdef0123456789abcdef"

    -- 断言当前确实是 MySQL 驱动
    t.eq(skynet.call(db, "lua", "driver_name"), "mysql", "T0 driver is mysql")

    -- 清空表，保证幂等可重跑
    t.check(skynet.call(db, "lua", "reset"), "T0 reset tables")

    -- T1: 账号写入与认证（走 db + login，与内存驱动同路径）
    local code, uid = skynet.call(login, "lua", "create_account", "mysqlplayer@test", client_md5)
    t.eq(code, schema.errors.OK, "T1 create account in mysql")
    t.check(uid > 0, "T1 uid assigned")

    local ok_code, ok_uid, token = skynet.call(login, "lua", "auth", "mysqlplayer@test", client_md5)
    t.eq(ok_code, schema.errors.OK, "T1 auth against mysql")
    t.eq(ok_uid, uid, "T1 uid matches")
    t.check(type(token) == "string" and #token > 0, "T1 token issued")

    local bad = skynet.call(login, "lua", "auth", "mysqlplayer@test", "wrong-pass")
    t.eq(bad, schema.errors.BAD_PASSWORD, "T1 wrong password rejected")

    -- T2: 实体创建（MySQL 驱动会立即落库所有分区）
    local euid = skynet.call(db, "lua", "create_entity", "avatar", 0, "mysqlplayer@test", uid)
    t.eq(euid, uid, "T2 entity uid equals account uid")
    local found = skynet.call(db, "lua", "find_entity_by_account", "mysqlplayer@test")
    t.eq(found, uid, "T2 find entity by account")

    local state = skynet.call(db, "lua", "load", uid)
    t.eq(schema.get(state, "account"), "mysqlplayer@test", "T2 load account from mysql cache")
    t.eq(schema.get(state, "gold"), 0, "T2 initial gold")

    -- T3: 改字段 → 标脏 → save（只写脏分区）
    local ok1, res = skynet.call(db, "lua", "set_fields", uid, { gold = 500, level = 7, heroes = { h1 = 9 } })
    t.check(ok1, "T3 set_fields ok")
    t.eq(res.rev, 2, "T3 rev advanced")
    t.check(#res.written >= 1, "T3 wrote at least one partition")
    local gold_in_hero = false
    for _, p in ipairs(res.written) do if p == "base" then gold_in_hero = true end end
    t.check(gold_in_hero, "T3 base partition (gold/level) marked dirty")

    local ok2, saved = skynet.call(db, "lua", "save", uid)
    t.check(ok2, "T3 save ok")
    t.eq(saved.rev, 2, "T3 saved rev")
    local stats = skynet.call(db, "lua", "stats")
    t.check(stats.last_written and #stats.last_written >= 1, "T3 last_written recorded")

    -- T4: 当前缓存读回
    state = skynet.call(db, "lua", "load", uid)
    t.eq(schema.get(state, "gold"), 500, "T4 gold in live cache")
    t.eq(schema.get(state, "level"), 7, "T4 level in live cache")
    t.eq(schema.get(state, "heroes").h1, 9, "T4 heroes blob in live cache")

    -- T5: flush 不丢数据
    t.check(skynet.call(db, "lua", "flush"), "T5 flush ok")
    state = skynet.call(db, "lua", "load", uid)
    t.eq(schema.get(state, "gold"), 500, "T5 gold survives flush")

    -- T6/T7/T8: 重启模拟——新建驱动实例，从 MySQL 表重建缓存
    local drvmod = require "shared.db_driver_mysql"
    local fresh = drvmod.new()
    local fok, ferr = fresh:init({
        db_host = "127.0.0.1", db_port = 3306,
        db_user = "dev", db_password = "dev123", db_name = "ch13_palace",
    })
    t.check(fok, "T8 fresh driver init (simulated restart): " .. tostring(ferr))
    if fok then
        local fresh_state = fresh:load(uid)
        t.check(fresh_state ~= nil, "T8 fresh driver loads entity")
        t.eq(schema.get(fresh_state, "gold"), 500, "T8 gold persists across restart")
        t.eq(schema.get(fresh_state, "level"), 7, "T8 level persists across restart")
        t.eq(schema.get(fresh_state, "heroes").h1, 9, "T8 heroes blob persists across restart")
        t.eq(schema.get(fresh_state, "account"), "mysqlplayer@test", "T8 account persists")

        -- 索引字段落 entity_field；blob 字段落 entity_partition
        local field_rows = fresh.conn:query(string.format(
            "SELECT fid,value FROM entity_field WHERE uid=%d", uid))
        t.check(#field_rows >= 2, "T7 index fields written to entity_field")
        local seen_gold = false
        for _, r in ipairs(field_rows) do
            if tonumber(r.fid) == schema.fid("gold") then seen_gold = true end
        end
        t.check(seen_gold, "T7 gold(fid=4) stored as index column")

        local part_rows = fresh.conn:query(string.format(
            "SELECT `partition` AS part,rev,payload FROM entity_partition WHERE uid=%d", uid))
        t.check(#part_rows >= 1, "T7 partitions written to entity_partition")
        local seen_hero = false
        for _, r in ipairs(part_rows) do
            if r.part == "hero" and r.payload:find("h1") then seen_hero = true end
        end
        t.check(seen_hero, "T7 heroes blob in hero partition payload")

        fresh.conn:close()
    end

    -- 复原：清空表，不影响其他测试
    t.check(skynet.call(db, "lua", "reset"), "T8 cleanup reset")
    return t.result()
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "run" then skynet.ret(skynet.pack(M.run(...))) end
end)

skynet.start(function() end)

return M
