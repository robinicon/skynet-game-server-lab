-- main.lua — ch12 启动入口（单节点）
--
-- 启动：gate_reconnect + 两个 uniqueservice（hotfix_mgr / db_stub），然后跑测试。
-- hotfix_mgr / db_stub 用 uniqueservice 保证单例，Agent 内部也能按名字取到同一实例。

local skynet  = require "skynet"
local conf    = require "runtime"

local function fatal(msg)
    skynet.error(msg)
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
    os.exit(1)
end

skynet.start(function()
    local gate = skynet.newservice("gate_reconnect")
    skynet.call(gate, "lua", "init", { node_name = conf.node_name })

    -- 预先创建两个单例（Agent 内部也会按名字 uniqueservice 取到同一实例）
    skynet.uniqueservice("hotfix_mgr")
    skynet.uniqueservice("db_stub")

    local tt = conf.test_target
    if not tt or tt == "" then
        skynet.error("[main] 常驻（无 test_target）")
        skynet.sleep(0x7FFFFFFF)
        return
    end

    skynet.error(string.format("[main] launching test: %s", tt))
    local svc = skynet.newservice(tt)
    local ok, res = pcall(skynet.call, svc, "lua", "run", gate)
    if not ok then
        io.stderr:write(string.format("[main] test %s crashed: %s\n", tt, tostring(res)))
        io.stderr:flush()
        os.exit(1)
    end
    local pass = (type(res) == "table") and (res.pass or 0) or 0
    local fail = (type(res) == "table") and (res.fail or 0) or 0
    io.write(string.format("\n=== TOTAL: %d PASS, %d FAIL ===\n", pass, fail))
    io.flush()
    os.exit(fail > 0 and 1 or 0)
end)
