-- gateway/login.lua — 登录服务
-- 依赖：shared/ + service/center + service/agent
--
-- 职责：
--   1. auth          —— 账号密码认证（委托 center）
--   2. login_by_token—— 免密重连（委托 center）
--   3. login_handler —— 为已认证玩家创建独立的 agent 服务并返回地址
--
-- 变更说明：旧版 agent 是同进程 table（agent_mod.create），现改为独立服务，
--           登录后 fd ↔ agent 的绑定由 gate 维护。

local skynet     = require "skynet"
local error_code = require "shared.error_code"
local service    = require "shared.service"

local center_addr = nil
local gate_addr   = nil

--- center 寻址（P3 分片预留）
-- 当前单实例，直接返回唯一 center。
-- 按 uid/username 分片时只需替换本函数（accounts 按 username 存储，
-- 所以分片键用 username；verify_token 需要 uid → center 的映射，
-- 届时应让 token 携带分片标记，或由 gate 侧缓存 uid → shard）。
-- 正式的多节点方案见 ch10_distributed。
-- sharding_key 暂不使用：单实例阶段恒返回唯一 center，
-- 保留形参是为了让调用点明确"这里将来要按什么分片"
local function pick_center(sharding_key)
    return center_addr
end

-- ========== Agent 对象池 ==========
-- 实测：skynet.newservice("agent") 在登录关键路径上占 25~29ms
-- （auth 只有 0.5~1ms），池化后每次登录省掉一次服务创建。
-- 池中的 agent 处于 idle 状态（alive=false），被取用后才 start(uid,...)。
local pool        = {}
local POOL_MAX    = tonumber(os.getenv("CH4_AGENT_POOL")) or 256
local POOL_PREWARM = tonumber(os.getenv("CH4_AGENT_PREWARM")) or 64

local function alloc_agent()
    local a = table.remove(pool)
    if a then
        return a
    end
    return skynet.newservice("agent")
end

local handlers = {}

function handlers.init(center, gate)
    center_addr = center
    gate_addr   = gate
    skynet.error(string.format("[login] init: center=%s gate=%s", tostring(center), tostring(gate)))
    return true
end

--- 账号密码认证
-- @return code, uid, token, reason
function handlers.auth(username, password)
    if not center_addr then
        return error_code.ERR_SERVICE_BUSY, nil, nil, "login not initialized"
    end
    local ok, resp = pcall(skynet.call, pick_center(username), "lua", "login", username, password)
    if not ok or type(resp) ~= "table" then
        skynet.error(string.format("[login] auth call failed: %s", tostring(resp)))
        return error_code.ERR_SERVICE_BUSY, nil, nil, "center unavailable"
    end
    return resp[1], resp[2], resp[3], resp[4]
end

--- 免密重连
function handlers.login_by_token(token)
    if not center_addr then
        return error_code.ERR_SERVICE_BUSY, nil, nil, "login not initialized"
    end
    local ok, resp = pcall(skynet.call, pick_center(), "lua", "login_by_token", token)
    if not ok or type(resp) ~= "table" then
        return error_code.ERR_SERVICE_BUSY, nil, nil, "center unavailable"
    end
    return resp[1], resp[2], resp[3], resp[4]
end

--- 认证通过后创建 Agent
-- @return agent 地址 | nil
--
-- CH4_NO_AGENT=1 时跳过 agent 创建（仅用于压测对照实验：
-- 量化 newservice 在端到端链路中的占比，不要在生产使用）
function handlers.login_handler(uid, token, fd)
    if os.getenv("CH4_NO_AGENT") == "1" then
        return skynet.self()
    end
    local agent = alloc_agent()
    local ok, code = pcall(skynet.call, agent, "lua", "start",
        uid, token, gate_addr, center_addr, skynet.self())
    if not ok or code ~= error_code.OK then
        skynet.error(string.format("[login] agent start failed: uid=%s err=%s",
            tostring(uid), tostring(code)))
        return nil
    end
    return agent
end

--- agent 登出后归还池（由 agent 主动 send）
function handlers.recycle(agent)
    if agent and #pool < POOL_MAX then
        pool[#pool + 1] = agent
    elseif agent then
        pcall(skynet.send, agent, "lua", "exit")
    end
    return true
end

--- 预热：并发创建空闲 agent，避免首批请求落在 newservice 上
-- 优先级：显式参数 n > 环境变量 CH4_AGENT_PREWARM > 模块默认 POOL_PREWARM。
-- main.lua 会把 conf.agent_prewarm 作为 n 传入；若希望用环境变量覆盖，需显式传
-- CH4_AGENT_PREWARM 并在 main 里传 nil（见 README 环境变量说明）。
function handlers.prewarm(n)
    n = tonumber(n) or POOL_PREWARM
    local done = 0
    for _ = 1, n do
        skynet.fork(function()
            -- 必须先创建再入池：newservice 会 yield，
            -- 若先算 index 再 yield，多个协程会算出同一个下标互相覆盖
            local a = skynet.newservice("agent")
            -- 热激活：完成首次调度，避免登录路径上吃到 ~28ms 冷唤醒
            pcall(skynet.call, a, "lua", "warmup")
            pool[#pool + 1] = a
            done = done + 1
        end)
    end
    local waited = 0
    while done < n and waited < 1000 do
        skynet.sleep(1)
        waited = waited + 1
    end
    return #pool
end

function handlers.pool_size()
    return #pool
end

function handlers.logout(uid)
    if not center_addr then
        return false
    end
    return pcall(skynet.call, pick_center(), "lua", "logout", uid)
end

service.start("login", handlers)
