-- service/gate_redirect.lua — 逻辑网关：维护 fd → agent 映射 + 跳转窗口期缓存
--
-- 真实生产里 gate 是管 socket 的（snax.gateserver），这里简化为"逻辑 gate"：
-- 不真开端口，只维护 fd → agent 的路由表，并模拟跳转时的"窗口期消息缓存"。
--
-- 跳转窗口期（begin_jump → rebind 之间）：客户端仍在发消息，但旧 agent 即将退出、
-- 新 agent 还没接管。这段时间 gate 把消息**暂存**（buffer），等新 agent 通过 rebind
-- 接管后**重放**给新 agent，保证消息不丢、不乱序。
--
-- 跨节点：agent 可能在别的节点（如 node_b）。gate 用 a.node 判断——和本节点同名就
-- 本地 skynet.send，否则 cluster.send 跨节点投递。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local MY = nil   -- 本 gate 所在节点名（由 init 注入，不用 cluster.nodename 依赖）

local fd_to_agent = {}   -- fd -> { node, addr, window, buffer }

-- 消息路由（必须在 CMD 之前定义，否则 CMD.rebind/forward 引用它是"前向 local"，
-- Lua 里 local 的作用域从声明行的下一行才开始，前向引用会被当成全局 nil）。
local function route(fd, msg)
    local a = fd_to_agent[fd]
    if not a then return end
    if a.window then
        a.buffer[#a.buffer + 1] = msg
        return
    end
    if a.node == MY then
        skynet.send(a.addr, "lua", "client_msg", fd, msg)
    else
        -- 跨节点投递：addr 是目标节点上的 service handle
        cluster.send(a.node, a.addr, "client_msg", fd, msg)
    end
end

local CMD = {}

function CMD.init(cfg)
    MY = cfg.node_name
    return true
end

-- 初次绑定：新 agent 上线，fd 指向它
function CMD.bind(fd, node, addr)
    fd_to_agent[fd] = { node = node, addr = addr, window = false, buffer = {} }
    return true
end

-- 跳转开始：打开窗口，之后的 forward 进 buffer
function CMD.begin_jump(fd)
    local a = fd_to_agent[fd]
    if a then a.window = true end
    return true
end

-- 跳转完成 / 回滚：把 fd 重新指向新 agent，关闭窗口并重放缓存
function CMD.rebind(fd, node, addr)
    local old = fd_to_agent[fd]
    local buf = (old and old.buffer) or {}
    fd_to_agent[fd] = { node = node, addr = addr, window = false, buffer = {} }
    for _, msg in ipairs(buf) do
        route(fd, msg)
    end
    return true
end

-- 客户端消息入口（测试或真实客户端都走这）
function CMD.forward(fd, msg)
    route(fd, msg)
    return true
end

-- 查询 fd 当前指向（测试用）
function CMD.get_agent(fd)
    local a = fd_to_agent[fd]
    if not a then return nil end
    return a.node, a.addr, a.window
end

-- 查询缓存中的消息（测试用，验证窗口期确实被缓存了）
function CMD.get_buffer(fd)
    local a = fd_to_agent[fd]
    if not a then return {} end
    return a.buffer
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
