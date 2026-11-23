-- service/agent_jumper.lua — 玩家 Agent（会跳转）
--
-- 两种诞生方式：
--   1) 全新：spawn(state=nil) → 自己调用 gate:bind，成为 fd 的 owner
--   2) 跳转进来：spawn(state=序列化状态) → 由跳转方在本节点 gate 上完成 rebind
--
-- 跳转流程 jump(target_node, target_scene, opts)：
--   1) gate:begin_jump(fd)          —— 打开窗口，期间客户端消息进缓存
--   2) (可选 stall，模拟窗口期)
--   3) cluster.call(target_node, "@scene_X", "accept", ...)  —— 目标场景只创建新 agent 并返回其地址
--   4) 成功 → 跳转方在**本节点** gate 上 rebind(fd, target_node, 新地址)，再退出旧 agent
--      失败 → gate:rebind(fd, MY, self) 回滚，继续留在原场景

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local uid, fd, gate, scene, node_name, online
local state  = nil
local received = {}   -- 收到的客户端消息（用于验证存活/状态）

local CMD = {}

function CMD.spawn(cfg)
    uid       = cfg.uid
    fd        = cfg.fd
    gate      = cfg.gate
    scene     = cfg.scene
    node_name = cfg.node_name or "node_a"
    online    = true
    received  = {}

    if cfg.state == nil then
        -- 全新：默认状态 + 自己绑定 gate
        state = { hp = 100, x = 0, y = 0, level = 1, name = "u" .. cfg.uid }
        skynet.call(gate, "lua", "bind", fd, node_name, skynet.self())
    else
        -- 跳转进来：状态由旧节点序列化而来，gate 重绑交给 scene_host
        state = cfg.state
    end
    return true
end

-- 序列化当前状态（跳转前由旧 agent 调用）
function CMD.serialize()
    return {
        hp    = state.hp,
        x     = state.x,
        y     = state.y,
        level = state.level,
        name  = state.name,
    }
end

-- 客户端消息：每条都动一下状态，证明 agent 是"活"的、状态在演进
function CMD.client_msg(fd, msg)
    received[#received + 1] = msg
    state.x = state.x + 1
    if type(msg) == "table" and msg.dmg then
        state.hp = state.hp - msg.dmg
    end
    return true
end

function CMD.get_received()
    return received
end

function CMD.get_state()
    return state
end

function CMD.get_meta()
    return { uid = uid, fd = fd, scene = scene, node = node_name, online = online }
end

-- 跳转
function CMD.jump(target_node, target_scene, opts)
    opts = opts or {}

    -- 1) 打开窗口：客户端消息进缓存
    skynet.call(gate, "lua", "begin_jump", fd)

    -- 2) 模拟窗口期（测试用）：让调用方有机会在窗口内注入消息
    if opts.stall then skynet.sleep(opts.stall) end

    -- 3) 请求目标场景接纳（scene_host 只创建新 agent 并返回地址，不重绑）
    --    节点名直接用已知的 target_node，不依赖跨边界多返回值，避免顺序错位的坑。
    local s = CMD.serialize()
    -- scene_host.accept 返回 (true, addr)：第一值是成功标志，第二值才是新 agent 地址。
    -- 必须三值解包——只接两个值会把成功标志(true)误当成地址。
    local ok, success, taddr = pcall(
        cluster.call, target_node, "@scene_" .. target_scene, "accept",
        uid, fd, s, node_name, gate
    )

    if not ok or not success or not taddr then
        -- 4a) 失败回滚：gate 重绑回自己，窗口关闭，缓存重放给自己
        skynet.call(gate, "lua", "rebind", fd, node_name, skynet.self())
        skynet.error(string.format("[agent %d] 跳转 %s/%s 失败，回滚: %s",
            uid, target_node, target_scene, tostring(taddr)))
        return false, "jump_failed:" .. tostring(taddr)
    end

    -- 4b) 成功：本节点（与 gate 同节点）本地把 fd 重绑到新 agent。
    --     新 agent 可能在别的节点（如 node_b），gate 按 target_node 决定本地 send 还是跨节点 send。
    skynet.call(gate, "lua", "rebind", fd, target_node, taddr)

    skynet.error(string.format("[agent %d] 跳转到 %s/%s 成功，旧 agent 退出",
        uid, target_node, target_scene))
    online = false
    skynet.sleep(0)   -- 让 rebind 的重放先跑完
    skynet.fork(function() skynet.sleep(0); skynet.exit() end)
    return true
end

function CMD.force_exit()
    online = false
    skynet.exit()
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
