-- main.lua — ch10_distributed 启动入口（三个节点共用）
--
-- 角色由 conf.node_name 决定：
--   auth     → 起 login_gateway，开 cluster 端口，等 center 就绪后跑测试
--   center*  → 起 center_dist + redis_auth，注册 "@center"，常驻
--
-- 用法：
--   make test        — 三节点跨进程测试
--   make test-hang   — 对照组：裸 cluster.call 在目标假死时会不会挂死
--   make run         — 三节点常驻，手动调试

local skynet = require "skynet.manager"
local conf   = require "runtime"

local function fatal(msg)
    skynet.error(msg)
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
    os.exit(1)
end

local function split_list(s)
    local t = {}
    if not s or s == "" then return t end
    for name in string.gmatch(s, "[%w_]+") do
        t[#t + 1] = name
    end
    return t
end

-- ---------------- center 节点 ----------------

local function run_center(c)
    local cd = skynet.newservice("center_dist")
    local ok, name = skynet.call(cd, "lua", "init", {
        node = c.node_name,
        port = tonumber(c.cluster_port) or 2532,
    })
    if not ok then fatal("[main] center_dist init failed: " .. tostring(name)) end
    skynet.name("CENTER", cd)
    skynet.error(string.format("[main] %s ready (cluster port %s)", c.node_name, tostring(c.cluster_port)))

    local life = tonumber(os.getenv("CH10_CENTER_LIFE"))
    if life then
        skynet.sleep(life)
        os.exit(0)
    end
    skynet.sleep(0x7FFFFFFF)   -- 常驻，由 Makefile kill
end

-- ---------------- auth 节点 ----------------

local function run_auth(c)
    local centers = split_list(c.center_nodes)
    if #centers == 0 then
        fatal("[main] auth 节点没有配置 center_nodes")
    end

    local gw = skynet.newservice("login_gateway")
    local ok, err = skynet.call(gw, "lua", "init", {
        centers = centers,
        port    = tonumber(c.cluster_port) or 2531,
    })
    if not ok then fatal("[main] login_gateway init failed: " .. tostring(err)) end
    skynet.name("LOGIN", gw)

    -- 等对端就绪。这里必须用 probe（绕过熔断），
    -- 否则启动期的失败会把熔断器直接打 open，之后所有请求都 fail-fast。
    local ready = false
    for i = 1, 100 do
        local all = true
        for _, n in ipairs(centers) do
            if not skynet.call(gw, "lua", "probe", n) then
                all = false
                break
            end
        end
        if all then ready = true; break end
        skynet.sleep(10)
    end
    if not ready then
        fatal("[main] center 节点未就绪，放弃")
    end
    skynet.call(gw, "lua", "reset")   -- 探测期的失败不计入统计
    skynet.error(string.format("[main] auth ready, centers=%s", table.concat(centers, ",")))

    local tt = c.test_target
    if not tt or tt == "" then
        skynet.error("[main] no test_target, auth node running (forever)")
        skynet.sleep(0x7FFFFFFF)
        return
    end

    local total_pass, total_fail = 0, 0
    for name in string.gmatch(tt, "[%w_]+") do
        skynet.error(string.format("[main] launching test service: %s", name))
        local svc = skynet.newservice(name)
        local ok2, res = pcall(skynet.call, svc, "lua", "run", gw)
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
end

skynet.start(function()
    local ok, err = pcall(function()
        if conf.node_name == "auth" then
            run_auth(conf)
        else
            run_center(conf)
        end
    end)
    if not ok then
        fatal("[main] FATAL: " .. tostring(err))
    end
end)
