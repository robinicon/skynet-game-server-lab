-- service/agent_reconnect.lua — 支持断线重连 + 热更新的玩家 Agent
--
-- 断线重连：
--   · on_disconnect：标记 offline，启动超时定时器（默认 100cs）
--   · on_reconnect ：新 fd 绑定回来，取消定时器，恢复 online
--   · 定时器到点仍 offline → 存盘 + 退出（延迟销毁，给重连留窗口）
--
-- 热更新：
--   · 业务逻辑在 shared/agent_logic(.lua|_v2.lua)，通过 require 加载
--   · reload(path)：刷新 package.loaded 后重新 require，切换逻辑版本
--   · hotfix_mgr 广播 reload 时，运行中 agent 在「当前协程」就地重载，无崩溃、无状态丢失
--
-- 注意：本服务不调用 skynet.name（本版本无此 API）；退出前用「先 retpack 再 fork 退出」。

local skynet = require "skynet"

-- 断线后等待重连的超时（cs，1cs=10ms）。可用 CH12_OFFLINE_TIMEOUT 覆盖（单测调参）。
local OFFLINE_TIMEOUT_CS = tonumber(os.getenv("CH12_OFFLINE_TIMEOUT")) or 100

local uid, fd, gate, online, state, logic
local logic_mod = "shared.agent_logic"
local offline_timer = nil

local CMD = {}

local function load_logic()
    package.loaded[logic_mod] = nil
    logic = require(logic_mod)
end

function CMD.spawn(cfg)
    uid   = cfg.uid
    fd    = cfg.fd
    gate  = cfg.gate
    online = true
    -- 加载当前线上版本（由 hotfix_mgr 统一管理，避免新旧 agent 逻辑分叉）
    local hfm = skynet.uniqueservice("hotfix_mgr")
    logic_mod = skynet.call(hfm, "lua", "get_path") or logic_mod
    load_logic()
    state = logic.new_state(uid)
    skynet.call(hfm, "lua", "register", skynet.self())
    -- 把自己绑定到 gate（fd → 本 agent），否则 gate.disconnect/reconnect 找不到本 agent
    skynet.call(gate, "lua", "bind", fd, "node_a", skynet.self())
    return true
end

-- 客户端消息：每条都动一下状态，证明 agent 是"活"的、状态在演进
function CMD.client_msg(msg)
    if not online then return false, "offline" end
    state = logic.process(state, msg)
    return true
end

-- 断线：进入 offline，启动超时定时器
function CMD.on_disconnect()
    online = false
    offline_timer = skynet.timeout(OFFLINE_TIMEOUT_CS, function()
        CMD.save_and_exit()
    end)
    return true
end

-- 重连：新 fd 绑定回来，取消定时器，恢复 online
function CMD.on_reconnect(newfd)
    fd = newfd
    online = true
    if offline_timer then
        skynet.cleartimer(offline_timer)
        offline_timer = nil
    end
    return true
end

-- 超时未重连：存盘 + 退出（延迟销毁，给重连留窗口）
function CMD.save_and_exit()
    local db = skynet.uniqueservice("db_stub")
    pcall(skynet.call, db, "lua", "save", uid, state)
    online = false
    -- 定时器回调里退出，无需 retpack；fork 一拍再 exit 确保日志/存盘落盘
    skynet.fork(function()
        skynet.sleep(0)
        skynet.exit()
    end)
    return true
end

-- 热更新：刷新并重新加载逻辑模块
function CMD.reload(path)
    logic_mod = path or logic_mod
    load_logic()
    return true, logic.VERSION
end

function CMD.get_state() return state end
function CMD.get_meta() return { uid = uid, online = online, fd = fd } end
function CMD.get_logic_version() return logic.VERSION end

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
