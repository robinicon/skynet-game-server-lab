-- main.lua — ch5_perf 启动入口
--
-- 启动顺序：
--   1. objservice  — 业务对象服务（服务级 profiling 对照）
--   2. test_<target> — 由 conf.test_target 决定（支持逗号分隔多个）
--
-- 用法：
--   make test    — 对象池正确性（18 用例）
--   make bench   — 池化 vs 非池化基准 + profiling
--   make all     — test + bench

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
        -- 1. 业务对象服务（供服务级 skynet.stat("cpu") 对照）
        local obj = skynet.newservice("objservice")
        skynet.name("OBJSVC", obj)
        skynet.error(string.format("[main] objservice started at %s", obj))

        -- 2. 测试
        local test_target = conf.test_target
        if not test_target or test_target == "" then
            skynet.error("[main] no test_target, service running (forever)")
            skynet.sleep(0xFFFFFFFF)
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
            local ok2, res = pcall(skynet.call, svc, "lua", "run", obj)
            if not ok2 then
                io.stderr:write(string.format("[main] test %s crashed: %s\n", name, tostring(res)))
                io.stderr:flush()
                total_fail = total_fail + 1
            elseif type(res) == "table" then
                total_pass = total_pass + (res.pass or 0)
                total_fail = total_fail + (res.fail or 0)
            else
                io.write(string.format("[main] test %s returned: %s\n", name, tostring(res)))
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
