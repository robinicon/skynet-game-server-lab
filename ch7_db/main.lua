-- main.lua — ch7_db 启动入口
--
-- 用法：
--   make test             — test_db + test_concurrency
--   make test-db          — 只跑 CRUD
--   make test-concurrency — 只跑并发安全
--   make test-nq          — 关闭 queue 的对照（应当观测到丢失更新）

local skynet = require "skynet.manager"
local conf   = require "runtime"

local function fatal(msg)
    skynet.error(msg)
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
    os.exit(1)
end

skynet.start(function()
    local ok, err = pcall(function()
        -- 1. DB 服务（唯一持有连接的进程，所有持久化请求汇聚于此）
        local db = skynet.newservice("db")
        local ok_init, res = pcall(skynet.call, db, "lua", "init", {
            kind         = conf.db_driver,
            latency      = tonumber(conf.db_latency) or 1,
            slow_uid     = tonumber(conf.db_slow_uid),
            pool_min     = tonumber(conf.pool_min) or 1,
            pool_max     = tonumber(conf.pool_max) or 8,
            pool_hard_max = tonumber(conf.pool_hard_max) or 32,
            -- mysql 连接参数（conf 中已配置本地 dev 账号）
            host         = conf.db_host,
            port         = tonumber(conf.db_port) or 3306,
            user         = conf.db_user,
            password     = conf.db_password,
            database     = conf.db_database,
        })
        if not ok_init or res ~= true then
            fatal("[main] FATAL: db init failed: " .. tostring(res))
        end
        skynet.name("DB", db)
        local st = skynet.call(db, "lua", "stats")
        skynet.error(string.format("[main] db started: driver=%s pool=%d/%d",
            tostring(st.driver), st.pool.total, st.pool.max))

        -- 2. 测试
        local test_target = conf.test_target
        if not test_target or test_target == "" then
            skynet.error("[main] no test_target, exiting")
            os.exit(0)
            return
        end

        local total_pass, total_fail = 0, 0
        local names = {}
        for name in string.gmatch(test_target, "[%w_]+") do
            names[#names + 1] = name
        end

        for _, name in ipairs(names) do
            skynet.error(string.format("[main] launching test service: %s", name))
            local svc = skynet.newservice(name)
            local ok2, res2 = pcall(skynet.call, svc, "lua", "run", db)
            if not ok2 then
                io.stderr:write(string.format("[main] test %s crashed: %s\n", name, tostring(res2)))
                io.stderr:flush()
                total_fail = total_fail + 1
            elseif type(res2) == "table" then
                total_pass = total_pass + (res2.pass or 0)
                total_fail = total_fail + (res2.fail or 0)
            else
                io.write(string.format("[main] test %s returned: %s\n", name, tostring(res2)))
            end
        end

        io.write(string.format("\n=== TOTAL: %d PASS, %d FAIL ===\n", total_pass, total_fail))
        io.write("\n")
        io.flush()
        os.exit(total_fail > 0 and 1 or 0)
    end)

    if not ok then
        fatal("[main] FATAL: " .. tostring(err))
    end
end)
