-- test/test_cluster.lua — 跨节点通信测试（运行在 auth 节点，center1/center2 必须已启动）
--
-- 覆盖：
--   D1  两节点登录            → center 服务在目标节点被正确调用（双向计数对齐）
--   D2  跨节点 token 验证      → 正确/错误/过期/串号，以及在线状态
--   D6  多节点负载均衡         → 请求分散到各节点，且同一 uid 恒定命中同一节点
--   D7  send vs call          → 高频路径用 send 的收益
--   D8  本地缓存              → 二次登录不再产生跨节点校验
--   D9  大包跨节点            → 128KB 往返完整性
--   D10 服务寻址              → @name 寻址；查询不存在的名字会抛错
--   D3  故障：不卡死           → 目标假死 / 节点名未解析，都要在超时内返回
--   D4  熔断                  → 连续失败后 fail-fast，不再堆积请求
--   D5  熔断恢复              → 冷却结束后自动半开 → 闭合
--
-- 顺序有讲究：故障注入（D3/D4/D5）必须放在最后，
-- 否则 center2 的熔断器打开后会污染前面的正常用例。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local gw

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

local function call(...)
    return skynet.call(gw, "lua", ...)
end

-- 取某个 center 的统计（走跨节点）。
-- 注意：这里必须用裸 cluster.call 直连，不能走 gateway 的 dist.call 封装——
-- 否则在 D4 熔断打开后，对 center2 的读统计会被熔断器 fail-fast 成 nil，
-- 下游 post2.ping 索引 nil 直接崩。center 本身健康，裸调用永远能拿到真实统计。
-- 注意 cluster.call 返回远端的多返回值 (true, stats_table)，pcall 外层再包一层
-- 成功标志，所以这里要 unpack 出 (ok, r1, r2)。
local function cstat(node)
    local ok, r1, r2 = pcall(cluster.call, node, "@center", "stats")
    if not ok then return nil, tostring(r1) end
    if not r1 then return nil, tostring(r2) end   -- 业务层 false
    return r2
end

local function gwstats()
    local ok, s = call("stats")
    return ok and s or nil
end

local COOLDOWN = tonumber(os.getenv("CH10_CB_COOLDOWN")) or 300

-- ============================================================

local function do_tests()
    out("")
    out("========== D1 两节点登录 + 双向计数对齐 ==========")
    local N = 100
    local ok, tokens = call("issue_batch", 1, N, 5000)
    check("D1.0", ok, "批量签发 token " .. N .. " 个")
    if not ok then return end

    local allok, firsterr = true, nil
    for u = 1, N do
        local ok2, src = call("login", u, tokens[u])
        if not ok2 then allok = false; firsterr = tostring(src); break end
    end
    check("D1.1", allok, string.format("%d 次跨节点登录全部成功 %s", N, firsterr or ""))

    local gs = gwstats()
    check("D1.2", gs and gs.cross == N,
        string.format("gateway 侧发起 verify_token %d 次", gs and gs.cross or -1))

    local s1, s2 = cstat("center1"), cstat("center2")
    if not (s1 and s2) then
        check("D1.3", false, "读取 center 统计失败")
        return
    end
    check("D1.3", s1.verify + s2.verify == N,
        string.format("center 侧收到 verify_token %d 次 (c1=%d c2=%d)",
            s1.verify + s2.verify, s1.verify, s2.verify))
    -- 关键：调用方计数 == 接收方计数之和。只信调用方返回值是不够的 ——
    -- cluster.call 返回 ok 只能证明「有人回了包」，不能证明「目标节点真的处理了」。
    check("D1.4", gs.cross == s1.verify + s2.verify,
        string.format("双向对齐 gateway=%d center=%d", gs.cross, s1.verify + s2.verify))

    out("")
    out("========== D2 跨节点 token 语义 ==========")
    local okA, tokA = call("issue", 90001, 5000)
    local okB, srcB = call("login", 90001, tokA)
    check("D2.1", okA and okB and srcB == "center",
        string.format("正确 token → ok=%s src=%s", tostring(okB), tostring(srcB)))

    local _, srcC = call("login", 90002, "this_token_does_not_exist")
    check("D2.2", srcC == "not_found", string.format("错误 token → %s", tostring(srcC)))

    local okD, tokD = call("issue", 90003, 2)     -- ttl 2cs = 20ms
    skynet.sleep(5)                                -- 等 50ms
    local _, srcD = call("login", 90003, tokD)
    check("D2.3", srcD == "expired", string.format("过期 token → %s", tostring(srcD)))

    local okE, tokE = call("issue", 90004, 5000)
    local _, srcE = call("login", 90005, tokE)     -- 拿 90004 的 token 登 90005
    check("D2.4", srcE == "uid_mismatch", string.format("串号 token → %s", tostring(srcE)))

    local _, node90001 = call("pick", 90001)
    local okF, packF = call("center_call", node90001, "is_online", 90001)
    check("D2.5", okF and packF[1] == true,
        string.format("登录后 is_online(90001) 在 %s 上为真", tostring(node90001)))

    out("")
    out("========== D6 多节点负载均衡（1000 次真实登录） ==========")
    local M2, FROM = 1000, 200001
    local ok6, tokens6 = call("issue_batch", FROM, M2, 5000)
    check("D6.0", ok6, "批量签发 1000 个 token（按 center 分组，只发 2 次跨节点请求）")
    if not ok6 then return end

    local b1, b2 = cstat("center1"), cstat("center2")
    local t0 = skynet.hpc()
    local okall = true
    for u = FROM, FROM + M2 - 1 do
        local ok2 = call("login", u, tokens6[u])
        if not ok2 then okall = false; break end
    end
    local cost_ms = (skynet.hpc() - t0) / 1e6
    local a1, a2 = cstat("center1"), cstat("center2")
    local d1, d2 = a1.verify - b1.verify, a2.verify - b2.verify
    check("D6.1", okall and d1 > 0 and d2 > 0,
        string.format("两个节点都收到了请求 center1=%d center2=%d", d1, d2))
    local dev = math.abs(d1 - d2) / ((d1 + d2) / 2)
    check("D6.2", dev < 0.25, string.format("分布偏差 %.1f%% (center1=%d center2=%d)", dev * 100, d1, d2))
    check("D6.3", d1 + d2 == M2, string.format("%d 次登录 = %d 次跨节点校验", M2, d1 + d2))
    out(string.format("[INFO] 1000 次跨节点登录总耗时 %.1f ms，单次均值 %.3f ms", cost_ms, cost_ms / M2))

    local _, p1 = call("pick", 333777)
    local _, p2 = call("pick", 333777)
    check("D6.4", p1 == p2,
        string.format("一致性哈希：同一 uid 恒定命中 %s", tostring(p1)))

    out("")
    out("========== D7 send vs call ==========")
    local BURST = 500
    local t1 = skynet.hpc()
    for i = 1, BURST do
        call("center_call", "center1", "ping")
    end
    local c_call = (skynet.hpc() - t1) / 1e6

    local pre = cstat("center1")
    local t2 = skynet.hpc()
    call("send_burst", "center1", BURST, 500000)
    local c_send = (skynet.hpc() - t2) / 1e6
    check("D7.1", c_send < c_call,
        string.format("send %d 次 %.2f ms < call %d 次 %.2f ms", BURST, c_send, BURST, c_call))
    skynet.sleep(30)
    local post = cstat("center1")
    check("D7.2", post.online - pre.online == BURST,
        string.format("异步 send 的 %d 条消息最终全部到达 (delta=%d)", BURST, post.online - pre.online))

    out("")
    out("========== D8 本地缓存 ==========")
    local g1 = gwstats()
    local ok8, src8 = call("login", 1, tokens[1])     -- uid 1 在 D1 已登录并被缓存
    check("D8.1", ok8 and src8 == "cache",
        string.format("二次登录命中本地缓存 src=%s", tostring(src8)))
    local g2 = gwstats()
    check("D8.2", g2.cross == g1.cross,
        string.format("缓存命中不产生跨节点校验 cross %d → %d", g1.cross, g2.cross))
    check("D8.3", g2.cache_hit > 0, string.format("累计缓存命中 %d 次", g2.cache_hit))

    out("")
    out("========== D9 大包跨节点 ==========")
    local big = string.rep("X", 128 * 1024)
    local t3 = skynet.hpc()
    local ok9, pack9 = call("center_call", "center1", "echo", big)
    local c_big = (skynet.hpc() - t3) / 1e6
    check("D9.1", ok9 and pack9[2] == big,
        string.format("128KB 字符串往返一致，耗时 %.2f ms", c_big))

    out("")
    out("========== D10 服务寻址 ==========")
    local qok, addr = pcall(cluster.query, "center1", "center")
    check("D10.1", qok and addr ~= nil,
        string.format("cluster.query(\"center1\",\"center\") = %s", tostring(addr)))
    local qok2 = pcall(cluster.query, "center1", "no_such_service_xyz")
    check("D10.2", not qok2,
        "查询不存在的名字会抛错（不是返回 nil，必须 pcall）")

    out("")
    out("========== D3 故障注入：必须超时返回，不能卡死 ==========")
    local t4 = skynet.hpc()
    local okh, resh = call("hang_call", "center2", 100)     -- timeout 100cs = 1000ms
    local c_hang = (skynet.hpc() - t4) / 1e6
    check("D3.1", (not okh) and resh == "timeout",
        string.format("目标服务假死 → 返回 %s", tostring(resh)))
    check("D3.2", c_hang >= 800 and c_hang <= 2200,
        string.format("实际耗时 %.1f ms（设定 1000ms）", c_hang))

    local okp, packp = call("center_call", "center1", "ping")
    check("D3.3", okp, "超时后进程存活，其他节点调用仍正常（对照组见 make test-hang）")

    -- __nowaiting=false + 节点名未解析：裸 cluster.call 会在 clusterd 内部永久阻塞
    call("reload", { __nowaiting = false })
    local t5 = skynet.hpc()
    local okg, resg = call("call_ex", "ghost", 50, "ping")
    local c_ghost = (skynet.hpc() - t5) / 1e6
    check("D3.4", (not okg) and resg == "timeout",
        string.format("节点名未解析 → 返回 %s（耗时 %.1f ms，设定 500ms）", tostring(resg), c_ghost))
    call("reload", { __nowaiting = true, ghost = false })
    skynet.sleep(10)
    local okp2 = call("center_call", "center1", "ping")
    check("D3.5", okp2, "恢复配置后 clusterd 未被拖死")

    local g3 = gwstats()
    out(string.format("[INFO] 超时放弃的协程数 leaked: center2=%d ghost=%d",
        (g3.dist["center2"] and g3.dist["center2"].leaked) or 0,
        (g3.dist["ghost"] and g3.dist["ghost"].leaked) or 0))

    out("")
    out("========== D4 熔断 ==========")
    call("hang_call", "center2", 30)
    call("hang_call", "center2", 30)
    local okb, b = call("breaker", "center2")
    check("D4.1", okb and b.st == "open", string.format("连续 3 次超时 → 状态 %s", tostring(b.st)))

    local pre2 = cstat("center2")
    local t6 = skynet.hpc()
    local okf, resf = call("center_call", "center2", "ping")
    local c_ff = (skynet.hpc() - t6) / 1e3
    check("D4.2", (not okf) and resf == "circuit_open",
        string.format("熔断期内 fail-fast → %s", tostring(resf)))
    check("D4.3", c_ff < 5000, string.format("fail-fast 耗时 %.1f us（对照：真实调用 300+ us）", c_ff))
    local post2 = cstat("center2")
    check("D4.4", post2.ping == pre2.ping,
        string.format("熔断期内不产生真实跨节点请求 (ping %d → %d)", pre2.ping, post2.ping))

    out("")
    out("========== D5 熔断恢复 ==========")
    skynet.sleep(COOLDOWN + 20)
    local okb2, b2 = call("breaker", "center2")
    check("D5.1", okb2 and b2.st == "open" and skynet.now() >= b2.open_until,
        string.format("冷却期已过 (now=%d open_until=%d)", skynet.now(), b2.open_until))
    local okp3, pack3 = call("center_call", "center2", "ping")
    check("D5.2", okp3, string.format("半开探测成功 → %s", tostring(pack3 and pack3[2])))
    local okb3, b3 = call("breaker", "center2")
    check("D5.3", okb3 and b3.st == "closed", string.format("状态回到 %s", tostring(b3.st)))

    local target = nil
    for u = 600001, 602000 do
        local _, nd = call("pick", u)
        if nd == "center2" then target = u; break end
    end
    if target then
        local oki, toki = call("issue", target, 5000)
        local okl, srcl = call("login", target, toki)
        check("D5.4", oki and okl and srcl == "center",
            string.format("恢复后 uid=%d 走 center2 登录成功", target))
    else
        check("D5.4", false, "找不到路由到 center2 的 uid")
    end

    out("")
    out("========== 汇总 ==========")
    local g = gwstats()
    out(string.format("[INFO] gateway: login=%d cross=%d cache_hit=%d send=%d fail=%d",
        g.login, g.cross, g.cache_hit, g.send, g.fail))
    for _, node in ipairs({ "center1", "center2" }) do
        local s = cstat(node)
        if s then
            out(string.format("[INFO] %s: verify=%d online=%d online_count=%d ping=%d echo=%d",
                node, s.verify, s.online, s.online_count, s.ping, s.echo))
        end
    end
    for _, node in ipairs({ "center1", "center2" }) do
        local s = g.dist[node]
        if s then
            out(string.format("[INFO] dist[%s]: total=%d ok=%d fail=%d timeout=%d sc=%d leaked=%d avg=%.0f us",
                node, s.total, s.ok, s.fail, s.timeout, s.short_circuit, s.leaked,
                s.total > 0 and (s.cost_ns / s.total / 1000) or 0))
        end
    end
end

-- ============================================================

local CMD = {}

function CMD.run(handle)
    gw = handle
    local ok, err = pcall(do_tests)
    if not ok then
        fail = fail + 1
        out("[FATAL] " .. tostring(err))
        out(debug.traceback())
    end
    out(string.format("\n=== test_cluster: %d PASS, %d FAIL ===", pass, fail))
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
