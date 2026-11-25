-- test/test_all.lua — 综合测试入口（依次跑 test_disconnect + test_hotfix）
--
-- 由 main 通过 run(gate) 启动。内部用 uniqueservice 取到 hotfix_mgr / db_stub，
-- 再分别 newservice 两个测试服务并调用其 run，最后汇总 pass/fail。

local skynet = require "skynet"

local pass, fail = 0, 0

local function out_all(s)
    io.write(s .. "\n")
    io.flush()
end

-- 跑一个子测试服务，并把它的 pass/fail 累加到总计数
local function run_one(name, gate, hf, db)
    local svc = skynet.newservice(name)
    local ok, res = pcall(skynet.call, svc, "lua", "run", gate, hf, db)
    if not ok then
        fail = fail + 1
        skynet.error(string.format("[test_all] %s crashed: %s", name, tostring(res)))
        return
    end
    pass = pass + (res.pass or 0)
    fail = fail + (res.fail or 0)
end

local CMD = {}

function CMD.run(gate)
    local hf = skynet.uniqueservice("hotfix_mgr")
    local db = skynet.uniqueservice("db_stub")
    out_all("========== ch12 综合测试（断线重连 + 热更新）==========")
    run_one("test_disconnect", gate, hf, db)
    run_one("test_hotfix", gate, hf, db)
    out_all(string.format("\n=== test_all: %d PASS, %d FAIL ===", pass, fail))
    return { pass = pass, fail = fail }
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.retpack(false, "unknown_cmd:" .. tostring(cmd))
            return
        end
        skynet.retpack(f(...))
    end)
end)
