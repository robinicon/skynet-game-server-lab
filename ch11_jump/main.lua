-- main.lua — ch11_jump 启动入口
--
-- node_a：起 gate + scene_a，然后跑测试（test_target）
-- node_b：起 scene_b，常驻（被 Makefile kill）
--
-- gate / scene_host 的 cluster 名字：
--   gate 注册为 "@gate"（其实测试直接传 handle，但注册一下便于调试）
--   scene_a 注册为 "@scene_a"，scene_b 注册为 "@scene_b"
--   agent 跳转时 cluster.call(target_node, "@scene_X", "accept", ...)

local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local conf    = require "runtime"

local function fatal(msg)
    skynet.error(msg)
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
    os.exit(1)
end

skynet.start(function()
    -- 开本节点的 cluster 监听端口（同时把本节点身份设为 conf.node_name）
    cluster.open(conf.node_name)

    if conf.node_name == "node_a" then
        local gate = skynet.newservice("gate_redirect")
        skynet.call(gate, "lua", "init", { node_name = "node_a" })

        local sa = skynet.newservice("scene_host")
        skynet.call(sa, "lua", "init", { scene = "a", node_name = "node_a" })

        local tt = conf.test_target
        if not tt or tt == "" then
            skynet.error("[main] node_a 常驻（无 test_target）")
            skynet.sleep(0x7FFFFFFF)
            return
        end

        skynet.error(string.format("[main] launching test: %s", tt))
        local svc = skynet.newservice(tt)
        local ok, res = pcall(skynet.call, svc, "lua", "run", gate, sa)
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
    else
        -- node_b：只起 scene_b
        local sb = skynet.newservice("scene_host")
        skynet.call(sb, "lua", "init", { scene = "b", node_name = "node_b" })
        skynet.error("[main] node_b ready (scene_b)")
        skynet.sleep(0x7FFFFFFF)
    end
end)
