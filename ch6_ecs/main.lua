-- main.lua — ch6_ecs 启动入口
--
-- 用法：
--   make test   — test_ecs（行为 + 基准）
--   make bench  — bench_ecs（只跑基准，规模梯度）

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
        -- 启动前先确认 C 扩展可用，否则后面的失败信息会很难定位
        local ok_c, ecs = pcall(require, "ecs_high")
        if not ok_c then
            fatal("[main] FATAL: cannot load ecs_high.so — run `make` first: " .. tostring(ecs))
        end
        skynet.error(string.format("[main] ecs_high loaded: %s", tostring(ecs)))

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
            local ok2, res = pcall(skynet.call, svc, "lua", "run")
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
