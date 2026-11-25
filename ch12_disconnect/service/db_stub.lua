-- service/db_stub.lua — 内存版存盘桩（uniqueservice 单例）
--
-- 仅用于演示「Agent 超时退出前把状态落盘」这条链路，并提供查询接口供测试断言。
-- 生产里应替换为真实 MySQL / Redis 服务（见 ch7_db）。

local skynet = require "skynet"

local saved = {}   -- uid -> state

local CMD = {}

function CMD.save(uid, state)
    saved[uid] = state
    return true
end

function CMD.get(uid)
    return saved[uid]
end

function CMD.count()
    local n = 0
    for _ in pairs(saved) do n = n + 1 end
    return n
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
