-- test/test_http.lua — HTTP 管理接口测试

local skynet = require "skynet"
local client = require "test.http_client"

local pass, fail = 0, 0
local out = {}

local function emit(s)
    out[#out + 1] = s
    io.write(s .. "\n")
end

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        emit(string.format("  PASS  %s", name))
    else
        fail = fail + 1
        emit(string.format("  FAIL  %s  %s", name, tostring(detail)))
    end
end

local handlers = {}

function handlers.run(http_addr, addr, port)
    pass, fail = 0, 0
    out = {}

    if not http_addr then
        emit("ERROR: http_mgr addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR" }
    end
    addr = addr or "127.0.0.1"
    port = tonumber(port) or 8899
    local token  = os.getenv("CH9_GM_TOKEN") or ""
    local secret = os.getenv("CH9_CALLBACK_SECRET") or ""

    emit(string.rep("=", 66))
    emit(string.format("ch9_http tests — http://%s:%d", addr, port))
    emit(string.rep("=", 66))

    -- ============================================================
    emit("\n=== H1: GET /health ===")
    local r1, e1 = client.request(addr, port, "GET", "/health")
    check("H1.1 request ok", r1 ~= nil, tostring(e1))
    check("H1.2 status 200", r1 and r1.status == 200, r1 and r1.status)
    check("H1.3 body is json", r1 and r1.body:sub(1, 1) == "{", r1 and r1.body:sub(1, 40))
    check("H1.4 contains status healthy",
        r1 and r1.body:find("healthy", 1, true) ~= nil)
    check("H1.5 contains node info",
        r1 and r1.body:find("uptime_s", 1, true) ~= nil)
    emit(string.format("  -- body: %s", r1 and r1.body:sub(1, 160) or "nil"))

    -- ============================================================
    emit("\n=== H2: POST /gm command=test ===")
    local body2 = client.form({ command = "test", echo = "hello" })
    local r2, e2 = client.request(addr, port, "POST", "/gm",
        { ["Authorization"] = "Bearer " .. token }, body2)
    check("H2.1 request ok", r2 ~= nil, tostring(e2))
    check("H2.2 status 200", r2 and r2.status == 200, r2 and r2.status)
    check("H2.3 echo returned", r2 and r2.body:find("hello", 1, true) ~= nil,
        r2 and r2.body)
    emit(string.format("  -- body: %s", r2 and r2.body:sub(1, 160) or "nil"))

    -- ============================================================
    emit("\n=== H3: unknown path → 404 ===")
    local r3 = client.request(addr, port, "GET", "/nope")
    check("H3.1 status 404", r3 and r3.status == 404, r3 and r3.status)
    check("H3.2 error in body", r3 and r3.body:find("no route", 1, true) ~= nil)

    -- ============================================================
    emit("\n=== H4: /gm without token → 401 ===")
    local r4 = client.request(addr, port, "POST", "/gm", nil,
        client.form({ command = "test" }))
    check("H4.1 status 401", r4 and r4.status == 401, r4 and r4.status)
    check("H4.2 unauthorized message",
        r4 and r4.body:find("unauthorized", 1, true) ~= nil)

    emit("\n=== H5: /gm with wrong token → 401 ===")
    local r5 = client.request(addr, port, "POST", "/gm",
        { ["Authorization"] = "Bearer wrong-token" },
        client.form({ command = "test" }))
    check("H5.1 status 401", r5 and r5.status == 401, r5 and r5.status)

    emit("\n=== H6: /gm unknown command → 400 ===")
    local r6 = client.request(addr, port, "POST", "/gm",
        { ["Authorization"] = "Bearer " .. token },
        client.form({ command = "no_such_cmd" }))
    check("H6.1 status 400", r6 and r6.status == 400, r6 and r6.status)
    check("H6.2 unknown command message",
        r6 and r6.body:find("unknown command", 1, true) ~= nil)

    emit("\n=== H7: /gm missing command → 400 ===")
    local r7 = client.request(addr, port, "POST", "/gm",
        { ["Authorization"] = "Bearer " .. token }, "")
    check("H7.1 status 400", r7 and r7.status == 400, r7 and r7.status)

    -- ============================================================
    emit("\n=== H8: /callback requires secret ===")
    local r8 = client.request(addr, port, "POST", "/callback", nil, "a=1")
    check("H8.1 no secret → 401", r8 and r8.status == 401, r8 and r8.status)
    local r8b = client.request(addr, port, "POST", "/callback",
        { ["Authorization"] = "Bearer " .. secret }, client.form({ a = 1, b = 2 }))
    check("H8.2 with secret → 200", r8b and r8b.status == 200, r8b and r8b.status)
    check("H8.3 echo received", r8b and r8b.body:find('"a"', 1, true) ~= nil,
        r8b and r8b.body)

    -- ============================================================
    emit("\n=== H9: method not allowed → 405 ===")
    local r9 = client.request(addr, port, "GET", "/callback")
    check("H9.1 GET /callback → 405", r9 and r9.status == 405, r9 and r9.status)

    -- ============================================================
    emit("\n=== H10: metrics aggregation (cross-service) ===")
    -- 指标必须由**独立服务**提供：跨服务只能传地址+命令名，不能传函数
    local demo = skynet.newservice("metrics_demo")
    local ok10 = skynet.call(http_addr, "lua", "register_metrics",
        "demo_service", demo, "metrics")
    check("H10.1 provider registered", ok10 == true, tostring(ok10))
    local r10 = client.request(addr, port, "GET", "/health")
    check("H10.2 metrics contains demo_service",
        r10 and r10.body:find("demo_service", 1, true) ~= nil)
    check("H10.3 metric value present",
        r10 and r10.body:find('"online":42', 1, true) ~= nil, r10 and r10.body)
    check("H10.4 pool metrics present",
        r10 and r10.body:find('"pool_total":8', 1, true) ~= nil, r10 and r10.body)

    -- ============================================================
    emit("\n=== H11: register custom GM command (by module path) ===")
    -- 同样不能传函数：GM 命令以模块名注册，服务端内部 require
    local ok11 = skynet.call(http_addr, "lua", "register_gm",
        "double", "shared.gm_double")
    check("H11.0 module registered", ok11 == true, tostring(ok11))
    local r11 = client.request(addr, port, "POST", "/gm",
        { ["Authorization"] = "Bearer " .. token },
        client.form({ command = "double", n = 21 }))
    check("H11.1 custom command works", r11 and r11.status == 200, r11 and r11.status)
    check("H11.2 result correct", r11 and r11.body:find('"result":42', 1, true) ~= nil,
        r11 and r11.body)

    -- ============================================================
    emit("\n=== H12: provider failure degrades but does not break /health ===")
    skynet.call(http_addr, "lua", "register_metrics",
        "broken", demo, "metrics_broken")
    local r12 = client.request(addr, port, "GET", "/health")
    check("H12.1 still 200", r12 and r12.status == 200, r12 and r12.status)
    check("H12.2 marked degraded",
        r12 and r12.body:find("degraded", 1, true) ~= nil, r12 and r12.body)
    check("H12.3 error captured with reason",
        r12 and r12.body:find("provider_errors", 1, true) ~= nil
           and r12.body:find("boom", 1, true) ~= nil,
        r12 and r12.body)
    skynet.call(http_addr, "lua", "unregister_metrics", "broken")

    -- ============================================================
    emit("\n=== H13: concurrent requests ===")
    local done, okc = 0, 0
    for _ = 1, 10 do
        skynet.fork(function()
            local r = client.request(addr, port, "GET", "/health")
            if r and r.status == 200 then okc = okc + 1 end
            done = done + 1
        end)
    end
    local waited = 0
    while done < 10 and waited < 500 do
        skynet.sleep(1)
        waited = waited + 1
    end
    emit(string.format("  -- %d/10 concurrent /health succeeded", okc))
    check("H13.1 all concurrent requests ok", okc == 10, okc)

    -- ============================================================
    emit("\n=== H14: stats interface ===")
    local st = skynet.call(http_addr, "lua", "stats")
    check("H14.1 routes listed", type(st.routes) == "table" and #st.routes >= 3,
        table.concat(st.routes or {}, ","))
    check("H14.2 commands listed", #st.commands >= 5, table.concat(st.commands or {}, ","))
    check("H14.3 providers listed", #st.providers >= 1,
        table.concat(st.providers or {}, ","))
    check("H14.4 token configured", st.gm_token_set == true)

    emit(string.rep("=", 66))
    emit(string.format("  Subtotal: %d PASS, %d FAIL", pass, fail))
    emit(string.rep("=", 66))

    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

require "shared.service".start("test_http", handlers)

return handlers
