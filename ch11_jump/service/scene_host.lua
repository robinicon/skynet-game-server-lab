-- service/scene_host.lua — 场景服：接收跳转进来的玩家，创建/接管 Agent
--
-- 关键方法 accept(uid, fd, state, from_node, gate)：
--   1) 在本节点 newservice 一个新的 agent_jumper
--   2) 用 state 初始化它（state 是旧节点序列化出来的玩家状态）
--   3) 返回 (true, new_agent_addr)
--
-- 注意：accept **不碰 gate**。fd 的重绑由跳转方在自己节点上完成
-- （跨节点对数字 handle 调 rebind 不可靠，故把 rebind 收回本地做）。
-- 如果 accept 失败（比如创建 agent 出错），返回 (false, reason)，跳转方据此回滚到原场景。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local scene_name = "?"
local my_node   = "?"
local agents    = {}   -- uid -> addr

local CMD = {}

function CMD.init(cfg)
    scene_name = cfg.scene or "?"
    my_node    = cfg.node_name or "?"
    cluster.register("scene_" .. scene_name, skynet.self())
    skynet.error(string.format("[scene_host] %s ready on %s", scene_name, my_node))
    return true, scene_name
end

-- 承接一次跳转
-- 注意：本函数**只负责创建新 agent 并返回它的地址**，不做 fd 重绑。
-- fd 重绑由跳转方（旧 agent 所在节点，与 gate 同节点）用本地 skynet.call 完成。
-- 原因：跨节点用数字 handle 做 cluster.call 重绑不可靠（目标集群通道投递数字
-- handle 会 "call to invalid address"）。把重绑收回到本节点做，链路最稳。
function CMD.accept(uid, fd, state, from_node, gate)
    local a = skynet.newservice("agent_jumper")
    local ok, err = skynet.call(a, "lua", "spawn", {
        uid       = uid,
        fd        = fd,
        gate      = gate,
        node_name = my_node,
        scene     = scene_name,
        state     = state,   -- 旧节点序列化出来的状态；nil 表示全新创建
    })
    if not ok then
        pcall(skynet.send, a, "lua", "force_exit")
        skynet.error(string.format("[scene_host %s] accept uid=%d 失败: %s",
            scene_name, uid, tostring(err)))
        return false, "spawn_failed:" .. tostring(err)
    end

    agents[uid] = a
    skynet.error(string.format("[scene_host %s] accept uid=%d -> agent :%08x (%s)",
        scene_name, uid, a, my_node))
    -- 只返回新 agent 地址；节点名由跳转方自己已知（target_node），不在跨边界多返回值上
    -- 赌顺序/数量，避免同节点 cluster.call 返回多值错位的坑。
    return true, a
end

function CMD.list()
    local t = {}
    for u, a in pairs(agents) do t[#t + 1] = { uid = u, addr = a } end
    return true, t
end

function CMD.count()
    local n = 0
    for _ in pairs(agents) do n = n + 1 end
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
