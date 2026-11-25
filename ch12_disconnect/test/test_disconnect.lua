-- test/test_disconnect.lua — 断线重连测试（运行在 node_a）
--
-- 三个用例对应 design.md Phase 9 的验收标准：
--   T1 断线 → Agent 进入 offline 状态（未 exit）
--   T2 重连 → fd 重绑，Agent 恢复 online
--   T3 超时未重连 → Agent 正常 exit，数据落盘
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

-- 检查某个 agent 是否还活着
local function alive(addr)
    local ok = pcall(skynet.call, addr, "lua", "get_meta")
    return ok
end

local function new_agent(uid, fd)
    local a = skynet.newservice("agent_reconnect")
    skynet.call(a, "lua", "spawn", { uid = uid, fd = fd, gate = gate })
    return a
end

-- 断线超时（与 agent_reconnect 里的 OFFLINE_TIMEOUT_CS 保持一致；可用环境变量覆盖）
local OFFLINE_TIMEOUT = tonumber(os.getenv("CH12_OFFLINE_TIMEOUT")) or 100

local function do_tests()
    out("")
    out("========== T1 断线 → Agent offline（未 exit）==========")
    local fd1 = 2001
    local a1 = new_agent(2001, fd1)
    skynet.call(gate, "lua", "disconnect", fd1)
    skynet.sleep(2)
    local m1 = skynet.call(a1, "lua", "get_meta")
    check("T1.1", m1 and m1.online == false, "断开后 offline")
    check("T1.2", alive(a1), "断开后 agent 仍存活(未 exit)")

    out("")
    out("========== T2 重连 → fd 重绑，恢复 online ==========")
    local fd2 = 2002
    local a2 = new_agent(2002, fd2)
    skynet.call(gate, "lua", "disconnect", fd2)
    skynet.sleep(2)
    -- 模拟客户端拿新 fd 重连
    skynet.call(gate, "lua", "reconnect", fd2, 2999)
    skynet.sleep(2)
    local m2 = skynet.call(a2, "lua", "get_meta")
    check("T2.1", m2 and m2.online == true, "重连后 online")
    check("T2.2", alive(a2), "重连后 agent 仍存活")
    check("T2.3", m2 and m2.fd == 2999, "fd 已更新为新 fd(2999)")

    out("")
    out("========== T3 超时未重连 → exit + 存盘 ==========")
    local fd3 = 2003
    local a3 = new_agent(2003, fd3)
    skynet.call(a3, "lua", "client_msg", { dmg = 10 })  -- 在线时制造状态 hp 100->90
    local s3 = skynet.call(a3, "lua", "get_state")
    check("T3.0", s3 and s3.hp == 90, "断线前状态 hp=90")
    skynet.call(gate, "lua", "disconnect", fd3)
    skynet.sleep(OFFLINE_TIMEOUT + 60)   -- 等超时定时器触发
    check("T3.1", not alive(a3), "超时后 agent 已 exit")
    local saved3 = skynet.call(db, "lua", "get", 2003)
    check("T3.2", saved3 ~= nil, "超时后已存盘")
    check("T3.3", saved3 and saved3.hp == 90,
        string.format("存盘状态正确 hp=%s (期望 90)", tostring(saved3 and saved3.hp)))
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
    out(string.format("\n=== test_disconnect: %d PASS, %d FAIL ===", pass, fail))
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
