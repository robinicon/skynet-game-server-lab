-- main.lua — ch9_http 启动入口
--
-- 用法：
--   make test   — HTTP 接口测试
--   make run    — 常驻（手动 curl 调试）

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
        -- 1. HTTP 管理服务
        local http = skynet.newservice("http_mgr")
        local addr = conf.http_address or "127.0.0.1"
        local port = tonumber(conf.http_port) or 8899
        local info = skynet.call(http, "lua", "init", {
            address = addr,
            port    = port,
            backlog = tonumber(conf.http_backlog) or 128,
            gm_token = os.getenv("CH9_GM_TOKEN") or "dev-token",
            cb_secret = os.getenv("CH9_CALLBACK_SECRET") or "dev-secret",
        })
        skynet.name("HTTPMGR", http)
        skynet.error(string.format("[main] http_mgr on %s:%d", tostring(info.address), tostring(info.port)))
        -- 给 listen 一点时间就绪
        skynet.sleep(2)

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
            local ok2, res = pcall(skynet.call, svc, "lua", "run", http, addr, port)
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
