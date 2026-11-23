-- service/gate_reconnect.lua — 逻辑网关：维护 fd → agent 映射 + 断线/重连
--
-- 真实生产里 gate 是 snax.gateserver 管 socket；这里简化为"逻辑 gate"：只维护
-- fd → agent 的路由表，并模拟"客户端断线"和"客户端重连"两个事件。
--
-- 断线（disconnect）：标记 fd 离线，通知 agent 进入 offline（启动超时定时器）。
-- 重连（reconnect）：新 fd 绑定到同一 agent，取消定时器，恢复 online。

local skynet = require "skynet"

local MY = nil
local fd_to_agent = {}   -- fd -> { node, addr, offline }

local CMD = {}

function CMD.init(cfg)
    MY = cfg.node_name
    return true
end

-- 初次绑定：新 agent 上线，fd 指向它
function CMD.bind(fd, node, addr)
    fd_to_agent[fd] = { node = node, addr = addr, offline = false }
    return true
end

-- 模拟客户端断线：标记离线，通知 agent 进入 offline（agent 内部启动超时定时器）
function CMD.disconnect(fd)
    local a = fd_to_agent[fd]
    if not a then return false end
    a.offline = true
    skynet.send(a.addr, "lua", "on_disconnect")
    return true
end

-- 模拟客户端重连：新 fd 绑定到同一 agent，取消定时器，恢复 online
function CMD.reconnect(fd, newfd)
    local a = fd_to_agent[fd]
    if not a then return false end
    fd_to_agent[newfd] = a
    fd_to_agent[fd] = nil
    skynet.send(a.addr, "lua", "on_reconnect", newfd)
    return true
end

-- 客户端消息入口（测试或真实客户端都走这）
function CMD.forward(fd, msg)
    local a = fd_to_agent[fd]
    if not a or a.offline then return false, "offline" end
    skynet.send(a.addr, "lua", "client_msg", msg)
    return true
end

-- 查询 fd 当前指向（测试用）
function CMD.get_agent(fd)
    local a = fd_to_agent[fd]
    if not a then return nil end
    return a.node, a.addr, a.offline
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
