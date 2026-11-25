-- test/test_hotfix.lua — 热更新测试（运行在 node_a）
--
-- 两个用例对应 design.md Phase 9 的验收标准：
--   T4 热更新模块 → 运行中 Agent 重载，无崩溃
--   T5 热更新添加新字段 → 旧 Agent 兼容，新 Agent 正常
--
-- 依赖：gate / hotfix_mgr / db_stub handle 由 test_all 通过 run(gate, hf, db) 传入。

local skynet = require "skynet"

local gate, hf, db
local pass, fail = 0, 0
local lines = {}

local function out(s)
    io.write(s .. "\n")
    io.flush()
    lines[#lines + 1] = s
end

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
        out(string.format("[PASS] %-6s %s", name, extra or ""))
    else
        fail = fail + 1
        out(string.format("[FAIL] %-6s %s", name, extra or ""))
    end
end

local function new_agent(uid, fd)
    local a = skynet.newservice("agent_reconnect")
    skynet.call(a, "lua", "spawn", { uid = uid, fd = fd, gate = gate })
    return a
end

local function do_tests()
    out("")
    out("========== T4 热更新模块 → 运行中 Agent 重载，无崩溃 ==========")
    local fd4 = 3001
    local a4 = new_agent(3001, fd4)
    local v0 = skynet.call(a4, "lua", "get_logic_version")
    check("T4.0", v0 == 1, "初始逻辑版本 v1")
    skynet.call(a4, "lua", "client_msg", { dmg = 5 })
    -- 部署 v2 + 广播 reload
    skynet.call(hf, "lua", "deploy_v2")
    skynet.sleep(3)
    local v1 = skynet.call(a4, "lua", "get_logic_version")
    check("T4.1", v1 == 2, string.format("热更后逻辑版本 v2 (原 v%d)", v0))
    -- 热更后仍能正常处理消息
    skynet.call(a4, "lua", "client_msg", { dmg = 5 })
    local s4 = skynet.call(a4, "lua", "get_state")
    check("T4.2", s4 and s4.hp == 90, "热更后消息处理正常 hp=90")
    -- 真实存活探针：再发一次调用，能正常返回才算存活（不能用恒真断言）
    local ok_alive, alive_ver = pcall(skynet.call, a4, "lua", "get_logic_version")
    check("T4.3", ok_alive and alive_ver == 2, "热更后 agent 仍存活可响应（无崩溃）")

    out("")
    out("========== T5 热更新添加新字段 → 旧 Agent 兼容，新 Agent 正常 ==========")
    -- a4 是旧 agent（v1 创建，state 无 mp），热更到 v2 后处理应补齐 mp（向前兼容）
    skynet.call(a4, "lua", "client_msg", {})
    local s_old = skynet.call(a4, "lua", "get_state")
    check("T5.1", s_old and s_old.mp ~= nil,
        string.format("旧 agent 热更后新字段被默认补齐 mp=%s", tostring(s_old and s_old.mp)))
    -- 新 agent 在 v2 环境下创建，自带 mp
    local fd5 = 3002
    local a5 = new_agent(3002, fd5)
    local s_new = skynet.call(a5, "lua", "get_state")
    check("T5.2", s_new and s_new.mp == 100, "新 agent 自带新字段 mp=100")
    skynet.call(a5, "lua", "client_msg", { dmg = 10 })
    local s_new2 = skynet.call(a5, "lua", "get_state")
    check("T5.3", s_new2 and s_new2.hp == 90, "新 agent 处理正常 hp=90")
end

local CMD = {}

function CMD.run(g, h, d)
    gate, hf, db = g, h, d
    local ok, err = pcall(do_tests)
    if not ok then
        fail = fail + 1
        out("[FATAL] " .. tostring(err))
        out(debug.traceback())
    end
    out(string.format("\n=== test_hotfix: %d PASS, %d FAIL ===", pass, fail))
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
