-- test/test_jump.lua — 跨节点跳转测试（运行在 node_a）
--
-- 四个用例对应 design.md Phase 8 的验收标准：
--   T1 同节点跳转 → fd 重绑成功，状态完整
--   T2 跨节点跳转 → 目标场景服收到完整状态
--   T3 跳转中客户端发消息 → Gate 缓存后正确转发（窗口期不丢消息）
--   T4 目标节点不可达 → 跳转失败，回滚到原场景（状态无丢失，agent 仍在线）
--
-- 依赖：gate handle、scene_a handle 由 main 通过 run(gate, scene_a) 传入。
-- scene_b 在 node_b，通过 cluster.call("node_b", "@scene_b", ...) 访问。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local gate, scene_a

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

-- 创建一个全新 agent 并绑定到 gate
local function new_agent(uid, fd)
    local a = skynet.newservice("agent_jumper")
    skynet.call(a, "lua", "spawn", {
        uid = uid, fd = fd, gate = gate, node_name = "node_a", scene = "a", state = nil,
    })
    return a
end

-- 检查某个 agent 是否还活着
local function alive(addr)
    local ok = pcall(skynet.call, addr, "lua", "get_meta")
    return ok
end

local function do_tests()
    out("")
    out("========== T1 同节点跳转（node_a → scene_a），状态完整 ==========")
    local fd1 = 1001
    local a1 = new_agent(1001, fd1)
    skynet.call(gate, "lua", "forward", fd1, { dmg = 10 })   -- 制造一点状态变化
    local s1 = skynet.call(a1, "lua", "get_state")
    check("T1.0", s1 and s1.hp == 90 and s1.x == 1,
        string.format("跳转前 state hp=%s x=%s", tostring(s1 and s1.hp), tostring(s1 and s1.x)))

    local ok1, err1 = skynet.call(a1, "lua", "jump", "node_a", "a")
    check("T1.1", ok1, "同节点跳转成功 " .. tostring(err1))
    skynet.sleep(5)

    local n1, addr1 = skynet.call(gate, "lua", "get_agent", fd1)
    check("T1.2", n1 == "node_a" and addr1 and addr1 ~= a1,
        string.format("fd 重绑到新 agent (node=%s, new=%s)", tostring(n1), tostring(addr1)))
    local s2 = skynet.call(addr1, "lua", "get_state")
    check("T1.3", s2 and s2.hp == s1.hp and s2.x == s1.x,
        string.format("状态完整 hp=%s x=%s (旧 hp=%s x=%s)",
            tostring(s2 and s2.hp), tostring(s2 and s2.x), tostring(s1.hp), tostring(s1.x)))
    check("T1.4", not alive(a1), "旧 agent 已退出")

    out("")
    out("========== T2 跨节点跳转（node_a → node_b/scene_b），状态完整 ==========")
    local fd2 = 1002
    local a2 = new_agent(1002, fd2)
    skynet.call(gate, "lua", "forward", fd2, { dmg = 25 })
    local s21 = skynet.call(a2, "lua", "get_state")
    check("T2.0", s21 and s21.hp == 75 and s21.x == 1, "跳转前 state 已演进")

    local ok2, err2 = skynet.call(a2, "lua", "jump", "node_b", "b")
    check("T2.1", ok2, "跨节点跳转成功 " .. tostring(err2))
    skynet.sleep(5)

    local n2, addr2 = skynet.call(gate, "lua", "get_agent", fd2)
    check("T2.2", n2 == "node_b" and addr2 and addr2 ~= a2,
        string.format("fd 重绑到 node_b 新 agent (node=%s)", tostring(n2)))
    local s22 = cluster.call("node_b", addr2, "get_state")
    check("T2.3", s22 and s22.hp == s21.hp and s22.x == s21.x,
        string.format("跨节点状态完整 hp=%s x=%s (旧 hp=%s x=%s)",
            tostring(s22 and s22.hp), tostring(s22 and s22.x), tostring(s21.hp), tostring(s21.x)))
    check("T2.4", not alive(a2), "旧 agent 已退出")

    out("")
    out("========== T3 跳转中客户端发消息 → Gate 窗口期缓存后转发 ==========")
    local fd3 = 1003
    local a3 = new_agent(1003, fd3)
    -- 异步发起跳转，并故意留出窗口期（stall=30cs ≈ 300ms）
    skynet.send(a3, "lua", "jump", "node_b", "b", { stall = 30 })
    skynet.sleep(5)   -- 等 begin_jump 生效（窗口打开）
    -- 窗口期内客户端发消息：应当被 gate 缓存，而非转给即将退出的旧 agent
    skynet.send(gate, "lua", "forward", fd3, "during_jump")
    skynet.sleep(60)  -- 等跳转完成 + 重放

    local n3, addr3 = skynet.call(gate, "lua", "get_agent", fd3)
    check("T3.1", n3 == "node_b" and addr3 and addr3 ~= a3, "跳转完成，新 agent 在 node_b")
    local rec3 = cluster.call("node_b", addr3, "get_received")
    local found = false
    for _, m in ipairs(rec3) do if m == "during_jump" then found = true; break end end
    check("T3.2", found, string.format("窗口期消息被重放到新 agent（received=%d）", #rec3))

    out("")
    out("========== T4 目标节点不可达 → 跳转失败，回滚 ==========")
    local fd4 = 1004
    local a4 = new_agent(1004, fd4)
    skynet.call(gate, "lua", "forward", fd4, { dmg = 5 })
    local s41 = skynet.call(a4, "lua", "get_state")
    check("T4.0", s41 and s41.hp == 95, "回滚前 state 正常")

    -- ghost 节点不在 clustername 里，且 __nowaiting=true → cluster.call 立即报错
    local ok4, err4 = skynet.call(a4, "lua", "jump", "ghost", "b")
    check("T4.1", not ok4, "跳转失败（不可达） " .. tostring(err4))
    skynet.sleep(5)

    local n4, addr4 = skynet.call(gate, "lua", "get_agent", fd4)
    check("T4.2", n4 == "node_a" and addr4 == a4,
        string.format("fd 仍绑在原 agent（未重绑）node=%s", tostring(n4)))
    check("T4.3", alive(a4), "原 agent 仍在线（未退出）")
    local s42 = skynet.call(a4, "lua", "get_state")
    check("T4.4", s42 and s42.hp == s41.hp and s42.x == s41.x, "状态无丢失")
    -- 回滚后客户端消息仍可正常投递
    skynet.call(gate, "lua", "forward", fd4, "after_rollback")
    local rec4 = skynet.call(a4, "lua", "get_received")
    local found4 = false
    for _, m in ipairs(rec4) do if m == "after_rollback" then found4 = true; break end end
    check("T4.5", found4, "回滚后消息仍正常到达原 agent")

    out("")
    out("========== 汇总 ==========")
    out(string.format("[INFO] scene_a 当前 agent 数: %d（应含 T1 新 agent）",
        skynet.call(scene_a, "lua", "count")))
    local okb, cntb = pcall(cluster.call, "node_b", "@scene_b", "count")
    out(string.format("[INFO] scene_b 当前 agent 数: %s（应含 T2/T3 新 agent）",
        tostring(okb and cntb)))
end

local CMD = {}

function CMD.run(g, sa)
    gate, scene_a = g, sa
    local ok, err = pcall(do_tests)
    if not ok then
        fail = fail + 1
        out("[FATAL] " .. tostring(err))
        out(debug.traceback())
    end
    out(string.format("\n=== test_jump: %d PASS, %d FAIL ===", pass, fail))
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
