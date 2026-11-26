-- test/test_hang.lua — 对照组：裸 cluster.call 在目标服务假死时的行为
--
-- 这个用例不返回。它故意发起一次没有任何超时保护的 cluster.call，
-- 目标服务的 hang 命令永不返回，所以整个进程会被挂住。
-- Makefile 用 `timeout N` 把它杀掉，用退出码 124 证明「确实挂死了」。
--
-- 与之对照：test_cluster.lua 的 D3.1 用 dist_call 包装后，
-- 同样的 hang 命令会在设定的超时时间内返回 "timeout"，进程继续正常服务。

local skynet = require "skynet"

local CMD = {}

function CMD.run(gw)
    io.write("[test_hang] 确认 center1 可达 ...\n")
    io.flush()
    local ok = skynet.call(gw, "lua", "probe", "center1")
    io.write("[test_hang] probe = " .. tostring(ok) .. "\n")
    io.write("[test_hang] 发起裸 cluster.call(\"center1\", \"@center\", \"hang\")，预期永不返回\n")
    io.flush()

    local ok2, res = pcall(skynet.call, gw, "lua", "raw_call", "center1", "@center", "hang")

    io.write("[test_hang] 竟然返回了（说明目标没有真的挂住）: "
        .. tostring(ok2) .. " " .. tostring(res) .. "\n")
    io.flush()
    return { pass = 0, fail = 1 }
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
