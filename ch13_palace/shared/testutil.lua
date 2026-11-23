-- shared/testutil.lua — 各测试服务共用的断言计数器

local M = {}

function M.new(name)
    local t = { name = name, pass = 0, fail = 0 }

    function t.check(cond, msg)
        if cond then
            t.pass = t.pass + 1
        else
            t.fail = t.fail + 1
            io.stderr:write(string.format("[%s] FAIL: %s\n", name, tostring(msg)))
            io.stderr:flush()
        end
    end

    function t.eq(actual, expected, msg)
        t.check(actual == expected,
            string.format("%s (got %s, want %s)", tostring(msg), tostring(actual), tostring(expected)))
    end

    function t.result()
        return { pass = t.pass, fail = t.fail }
    end

    return t
end

return M
