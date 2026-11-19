-- service/agent.lua — 玩家 Agent（每个在线玩家一个独立 snlua 服务）
-- 依赖：proto/ + shared/
--
-- 职责：
--   1. 持有玩家状态（uid / token / gate / center）
--   2. 启动后向 center 登记（register_agent）
--   3. 处理客户端业务消息（ping / echo）
--   4. 退出前通知 center 注销
--
-- 变更说明：旧版 agent 是 login 服务内的一个 table（无独立消息循环、无隔离），
--           现改为真实服务，登录链路由 login 服务 newservice 创建。

local skynet     = require "skynet"
local error_code = require "shared.error_code"
local service    = require "shared.service"
local proto      = require "proto.proto"

-- 业务消息 cmd 常量（与 proto/game.proto 注释一致）
local CMD_PING = 1
local CMD_ECHO = 2

local uid      = nil
local token    = nil
local gate     = nil
local center   = nil
local manager  = nil   -- login 服务地址（对象池管理者）
local alive    = false

local handlers = {}

--- 由 login 服务调用：初始化并向 center 登记
-- @param m login 服务地址，登出后向它归还自身（对象池复用，避免每次登录 newservice）
function handlers.start(u, t, g, c, m)
    uid, token, gate, center, manager = u, t, g, c, m

    local ok, code = pcall(skynet.call, c, "lua", "register_agent", u, skynet.self())
    if not ok or code ~= error_code.OK then
        skynet.error(string.format("[agent] register failed: uid=%s code=%s", tostring(u), tostring(code)))
        alive = false
        return error_code.ERR_INTERNAL
    end

    alive = true
    return error_code.OK
end

--- 主动登出：注销后归还对象池（不退出服务，等待下次复用）
function handlers.logout()
    if not alive then
        return true
    end
    alive = false
    pcall(skynet.send, center, "lua", "logout", uid)
    if manager then
        pcall(skynet.send, manager, "lua", "recycle", skynet.self())
    end
    return true
end

--- 连接断开（ch12 断线重连的预留入口：当前直接登出并归还池）
function handlers.afk()
    return handlers.logout()
end

--- 预热探针：不做任何业务，仅用于让服务完成首次调度
-- 实测：一个 agent 服务首次被 skynet.call 时有 ~28ms 的冷唤醒成本
-- （第二次起降到 0.2ms）。预热时调用一次，把这笔开销挪到启动阶段，
-- 而不是压在每次登录的关键路径上。
function handlers.warmup()
    return true
end

--- 池容量超出时由 login 服务回收
function handlers.exit()
    handlers.logout()
    skynet.exit()
    return true
end

--- 客户端业务消息：1 字节 cmd + sproto payload
function handlers.client(body)
    if not alive then
        return ""
    end
    if type(body) ~= "string" or #body < 1 then
        return ""
    end

    local cmd = string.byte(body, 1)
    local payload = body:sub(2)

    local ok, resp = pcall(function()
        if cmd == CMD_PING then
            local req = proto.decode("Ping", payload)
            return string.char(CMD_PING) .. proto.encode("Pong", {
                timestamp = req.timestamp or 0,
                latency   = math.floor(skynet.time() * 1000) % 1000000,
            })
        elseif cmd == CMD_ECHO then
            local req = proto.decode("echo_req", payload)
            return string.char(CMD_ECHO) .. proto.encode("echo_resp", {
                content = req.content or "",
            })
        end
        return ""
    end)

    if not ok then
        skynet.error(string.format("[agent] client msg error: uid=%s err=%s", tostring(uid), tostring(resp)))
        return ""
    end
    return resp
end

function handlers.info()
    return { uid = uid, alive = alive, gate = gate }
end

service.start("agent", handlers, {
    on_init = function()
        skynet.error(string.format("[agent] created: %s", tostring(skynet.self())))
    end,
})
