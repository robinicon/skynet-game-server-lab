-- gateway/main.lua — 启动入口
-- 依赖：所有层
--
-- 启动顺序（严格向下依赖）：
--   1. proto.init()      — 预编译协议
--   2. center            — 账号中心
--   3. login             — 登录服务（注入 center/gate）
--   4. gate              — 网关（注入 login，open 监听端口）
--   5. test_<target>     — 测试服务（由 conf.test_target 决定，支持逗号分隔多个）
--
-- 用法：
--   make run            — 启动服务（无测试，常驻）
--   make test           — 运行全部单元测试
--   make test-login     — 运行 T1/T2
--   make test-center    — 运行 T3/T4
--   make stress         — center 单点吞吐压测
--   make stress-e2e     — 端到端压测（TCP + 协议 + agent）

-- skynet.name / skynet.launch 等由 skynet.manager 扩展提供
local skynet = require "skynet.manager"
local conf   = require "runtime"
local proto  = require "proto.proto"

local function fatal(msg)
    skynet.error(msg)
    -- skynet.error 走异步 logger，进程随即退出会丢日志；stderr 无缓冲必达
    io.stderr:write(msg .. "\n")
    io.stderr:flush()
    os.exit(1)
end

skynet.start(function()
    -- 任何启动/测试阶段的异常都必须让进程退出（否则 skynet 节点常驻，
    -- make 会因收不到退出码而挂死）
    local ok, err = pcall(function()
        -- 1. 预编译协议
        proto.init()

        -- 2. 账号中心
        local center = skynet.newservice("center")
        skynet.name("CENTER", center)
        skynet.error(string.format("[main] center started at %s", center))

        -- 3. 登录服务 + 网关（旧版缺失，导致 gateway 层整体空转）
        local login = skynet.newservice("login")
        -- 服务名不能用 "gate"：../skynet/service/?.lua 下有同名内置服务（C gate 的 lua 封装）
        local gate  = skynet.newservice("gated")
        skynet.call(login, "lua", "init", center, gate)
        skynet.call(gate,  "lua", "init", login)
        skynet.error(string.format("[main] login=%s gate=%s", login, gate))

        -- 预热 agent 对象池：登录关键路径上的 newservice 实测 25~29ms/次
        -- 优先级：CH4_AGENT_PREWARM 环境变量 > conf.agent_prewarm > 64
        local prewarm_n = tonumber(os.getenv("CH4_AGENT_PREWARM"))
            or tonumber(conf.agent_prewarm) or 64
        local warmed = skynet.call(login, "lua", "prewarm", prewarm_n)
        skynet.error(string.format("[main] agent pool prewarmed: %d", warmed))

        local port      = tonumber(conf.gate_port) or 8888
        local maxclient = tonumber(conf.maxclient) or 2048
        skynet.call(gate, "lua", "open", {
            address   = conf.gate_address or "0.0.0.0",
            port      = port,
            maxclient = maxclient,
            -- backlog 必须显式设置：socketdriver.listen 默认 32，
            -- 100 个并发连接会撑满队列导致 SYN 被丢弃、客户端 1s 后才重传
            backlog   = tonumber(conf.gate_backlog) or 1024,
            nodelay   = true,
        })

        -- 4. 测试
        local test_target = conf.test_target
        if not test_target or test_target == "" then
            skynet.error("[main] no test_target, service running (forever)")
            skynet.sleep(0xFFFFFFFF)  -- 永不退出
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
            local ok2, res = pcall(skynet.call, svc, "lua", "run", center, gate, login)
            if not ok2 then
                io.stderr:write(string.format("[main] test %s crashed: %s\n", name, tostring(res)))
                total_fail = total_fail + 1
            elseif type(res) == "table" then
                total_pass = total_pass + (res.pass or 0)
                total_fail = total_fail + (res.fail or 0)
                -- 用例自身的 io.write 已实时输出明细，这里不重复打印 summary
            else
                io.write(string.format("[main] test %s returned: %s\n", name, tostring(res)))
            end
        end

        io.write(string.format("\n=== TOTAL: %d PASS, %d FAIL ===\n", total_pass, total_fail))
        io.write("\n")
        os.exit(total_fail > 0 and 1 or 0)
    end)

    if not ok then
        fatal("[main] FATAL: " .. tostring(err))
    end
end)
