-- test/test_login.lua — T1/T2：单账号登录单元测试
--
-- 运行方式：make test-login
-- 由 gateway/main.lua 启动并触发：skynet.call(test_service, "lua", "run", center, gate, login)
-- 返回：{ pass, fail, summary }（不再自行 os.exit，由 main 统一汇总退出码）

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

    -- 用例自治：单进程跑多个用例时先清空在线状态，避免相互污染
    pcall(skynet.call, center, "lua", "logout_all")

    emit("\n=== T1: Valid login ===")
    local ok, resp = pcall(skynet.call, center, "lua", "login", "admin", "admin123")
    if ok and resp and resp[1] == error_code.OK then
        check("T1a: admin login returns OK", true, error_code.OK, resp[1])
        check("T1b: uid is positive integer", resp[2] and resp[2] > 0, true, resp[2])
        check("T1c: token is non-empty string", type(resp[3]) == "string" and #resp[3] > 0, true, resp[3])
    else
        check("T1a: admin login success", false, "OK", ok and resp and resp[1] or "error")
    end

    emit("\n=== T2: Invalid login ===")
    local ok2, resp2 = pcall(skynet.call, center, "lua", "login", "nobody", "xxx")
    check("T2a: unknown account rejected",
          ok2 and resp2 and resp2[1] == error_code.ERR_UNKNOWN_ACCOUNT,
          error_code.ERR_UNKNOWN_ACCOUNT, ok2 and resp2 and resp2[1])

    local ok3, resp3 = pcall(skynet.call, center, "lua", "login", "admin", "wrongpassword")
    check("T2b: wrong password rejected",
          ok3 and resp3 and resp3[1] == error_code.ERR_WRONG_PASSWORD,
          error_code.ERR_WRONG_PASSWORD, ok3 and resp3 and resp3[1])

    local ok4, resp4 = pcall(skynet.call, center, "lua", "login", "admin", "admin123")
    check("T2c: duplicate login rejected",
          ok4 and resp4 and resp4[1] == error_code.ERR_ALREADY_LOGGED_IN,
          error_code.ERR_ALREADY_LOGGED_IN, ok4 and resp4 and resp4[1])

    -- T2d: token 形态校验（新策略：随机串，不含 uid|timestamp 明文）
    local ok5, resp5 = pcall(skynet.call, center, "lua", "login", "player1", "pass1")
    if ok5 and resp5 and resp5[1] == error_code.OK then
        local t = resp5[3]
        check("T2d: token carries no uid/timestamp plaintext",
              type(t) == "string" and t:find("|", 1, true) == nil, true, t)
    else
        check("T2d: token carries no uid/timestamp plaintext", false, "OK", ok5 and resp5 and resp5[1])
    end

    emit(string.format("\nResults: %d PASS, %d FAIL", pass, fail))
    return { pass = pass, fail = fail, summary = table.concat(out, "\n") }
end

local handlers = {}
function handlers.run(center)
    return run(center)
end

require "shared.service".start("test_login", handlers)

return handlers
