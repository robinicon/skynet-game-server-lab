-- test/test_center.lua — T3/T4：并发保护与 Token 验证单元测试
--
-- 运行方式：make test-center
-- 由 gateway/main.lua 启动并触发：skynet.call(test_service, "lua", "run", center, gate, login)
-- 回复约定：center 的 login/verify_token 返回单表 {code, uid, ...}
-- 返回：{ pass, fail, summary }

local skynet     = require "skynet"
local error_code = require "shared.error_code"

local out = {}

local function emit(line)
    out[#out + 1] = line
    io.write(line .. "\n")
end

local function run(center)
    local pass, fail = 0, 0

    local function check(name, cond, expected, got)
        if cond then
            pass = pass + 1
            emit(string.format("  PASS: %s", name))
        else
            fail = fail + 1
            emit(string.format("  FAIL: %s (expected=%s got=%s)", name, tostring(expected), tostring(got)))
        end
    end

    if not center then
        emit("ERROR: center addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR: no center" }
    end

    -- 用例自治：清空在线状态（前序用例可能留存 admin/player1 在线）
    pcall(skynet.call, center, "lua", "logout_all")

    emit("\n=== T3: Concurrent login protection ===")
    local ok1, r1 = pcall(skynet.call, center, "lua", "login", "admin", "admin123")
    check("T3a: first login succeeds",
          ok1 and r1 and r1[1] == error_code.OK,
          error_code.OK, ok1 and r1 and r1[1])

    local ok2, r2 = pcall(skynet.call, center, "lua", "login", "admin", "admin123")
    check("T3b: second login same account rejected",
          ok2 and r2 and r2[1] == error_code.ERR_ALREADY_LOGGED_IN,
          error_code.ERR_ALREADY_LOGGED_IN, ok2 and r2 and r2[1])

    local ok3, r3 = pcall(skynet.call, center, "lua", "login", "player1", "pass1")
    check("T3c: different account can login",
          ok3 and r3 and r3[1] == error_code.OK,
          error_code.OK, ok3 and r3 and r3[1])

    emit("\n=== T4: Token verification ===")
    if not (ok1 and r1 and r1[1] == error_code.OK) then
        check("T4: skipped (no token from T3a)", false, "token", "nil")
    else
        local ok4, r4 = pcall(skynet.call, center, "lua", "verify_token", r1[3])
        check("T4a: valid token returns uid",
              ok4 and r4 and r4[1] == error_code.OK and r4[2] == r1[2],
              true, ok4 and r4 and string.format("code=%s uid=%s", tostring(r4[1]), tostring(r4[2])))

        local ok5, r5 = pcall(skynet.call, center, "lua", "verify_token", "invalid-token-xxx")
        check("T4b: invalid token rejected",
              ok5 and r5 and r5[1] ~= error_code.OK, "~= OK", ok5 and r5 and r5[1])

        local ok6, r6 = pcall(skynet.call, center, "lua", "verify_token", "randomgarbage")
        check("T4c: random string rejected",
              ok6 and r6 and r6[1] ~= error_code.OK, "~= OK", ok6 and r6 and r6[1])

        skynet.call(center, "lua", "logout", r1[2])
        local ok7, r7 = pcall(skynet.call, center, "lua", "verify_token", r1[3])
        check("T4d: token invalid after logout",
              ok7 and r7 and r7[1] ~= error_code.OK, "~= OK", ok7 and r7 and r7[1])
    end

    emit("\n=== T7: Agent registration & metrics ===")
    local ok8, r8 = pcall(skynet.call, center, "lua", "register_agent", 1, skynet.self())
    check("T7a: register_agent on offline uid rejected",
          ok8 and r8 ~= error_code.OK, "~= OK", ok8 and r8)

    local ok9, r9 = pcall(skynet.call, center, "lua", "register_agent", 2, skynet.self())
    check("T7b: register_agent on online uid accepted",
          ok9 and r9 == error_code.OK, error_code.OK, ok9 and r9)

    local ok10, r10 = pcall(skynet.call, center, "lua", "online_count")
    check("T7c: online_count returns number",
          ok10 and type(r10) == "number", "number", ok10 and r10)

    local ok11, r11 = pcall(skynet.call, center, "lua", "stats")
    check("T7d: stats returns metrics table",
          ok11 and type(r11) == "table" and type(r11.login_ok) == "number",
          "table", ok11 and type(r11))

    emit(string.format("\nResults: %d PASS, %d FAIL", pass, fail))
    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

local handlers = {}
function handlers.run(center)
    return run(center)
end

require "shared.service".start("test_center", handlers)

return handlers
