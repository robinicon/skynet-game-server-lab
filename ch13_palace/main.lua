-- main.lua — ch13_palace 启动入口
--
--   make test          — 跑全部测试服务
--   make test-one T=.. — 跑单个测试服务
--   make run           — 常驻（不跑测试）

local skynet = require "skynet.manager"
local conf   = require "runtime"

skynet.start(function()
    local ok, err = pcall(function()
        local db = skynet.newservice("db")
        skynet.call(db, "lua", "init", {
            snapshot_path = conf.snapshot_path,
            driver        = conf.db_driver,
            db_host       = conf.db_host,
            db_port       = conf.db_port,
            db_user       = conf.db_user,
            db_password   = conf.db_password,
            db_name       = conf.db_name,
        })
        skynet.name("DB", db)

        local login = skynet.newservice("login")
        skynet.call(login, "lua", "init", db)
        skynet.name("LOGIN", login)

        -- P0.5：跨服中心（最小可运行排行链路），与网关并存
        local hub = skynet.newservice("hub")
        skynet.call(hub, "lua", "init", { snapshot_path = conf.hub_snapshot_path or "data/hub-snapshot.json" })
        skynet.name("HUB", hub)

        -- 阶段 5：对账回放模式（不起网关，跑完样本即退出）
        if conf.replay_file then
            local replay = skynet.newservice("replay")
            local res = skynet.call(replay, "lua", "run", db, hub)
            skynet.error("[main] replay done: " .. tostring(res and res.cases or 0) .. " cases")
            os.exit(res and res.ok and 0 or 1)
        end

        -- 阶段 1：TCP 网关（服务名 gated，避开 skynet 内置 gate）
        local gate = skynet.newservice("gated")
        skynet.call(gate, "lua", "init", db, login, { grace = conf.session_grace })
        skynet.call(gate, "lua", "set_hub", hub)
        skynet.name("GATE", gate)
        skynet.call(gate, "lua", "open", {
            address   = conf.gate_address or "127.0.0.1",
            port      = tonumber(conf.gate_port) or 9813,
            maxclient = tonumber(conf.maxclient) or 256,
            backlog   = tonumber(conf.backlog) or 256,
            nodelay   = true,
        })
        skynet.error(string.format("[main] gate listening on %s:%s",
            tostring(conf.gate_address or "127.0.0.1"), tostring(conf.gate_port or 9813)))

        -- P0：WebSocket 网关（Unity / 微信小游戏入口），与 TCP 网关并存
        local ws_gate_addr
        if conf.ws_enabled ~= "false" then
            local ws = skynet.newservice("ws_gate")
            skynet.call(ws, "lua", "init", db, login, { grace = conf.session_grace })
            skynet.call(ws, "lua", "set_hub", hub)
            skynet.name("WSGATE", ws)
            skynet.call(ws, "lua", "open", {
                address = conf.ws_gate_address or "127.0.0.1",
                port    = tonumber(conf.ws_gate_port) or 9814,
            })
            ws_gate_addr = ws
            skynet.error(string.format("[main] ws gate listening on ws://%s:%s",
                tostring(conf.ws_gate_address or "127.0.0.1"), tostring(conf.ws_gate_port or 9814)))
        end

        local target = conf.test_target
        if not target or target == "" then
            skynet.error("[main] no test_target, running in service mode")
            return
        end

        local total_pass, total_fail = 0, 0
        for name in string.gmatch(target, "[%w_]+") do
            skynet.error("[main] launching test: " .. name)
            local svc = skynet.newservice(name)
            local ok2, res = pcall(skynet.call, svc, "lua", "run", db, login, gate, ws_gate_addr, hub)
            if not ok2 then
                io.stderr:write(string.format("[main] test %s crashed: %s\n", name, tostring(res)))
                io.stderr:flush()
                total_fail = total_fail + 1
            elseif type(res) == "table" then
                total_pass = total_pass + (res.pass or 0)
                total_fail = total_fail + (res.fail or 0)
            end
        end

        io.write(string.format("\n=== TOTAL: %d PASS, %d FAIL ===\n", total_pass, total_fail))
        io.flush()
        os.exit(total_fail > 0 and 1 or 0)
    end)

    if not ok then
        io.stderr:write("[main] FATAL: " .. tostring(err) .. "\n")
        io.stderr:flush()
        os.exit(1)
    end
end)
