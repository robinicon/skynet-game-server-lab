-- service/hotfix_mgr.lua — 热更新广播管理器（uniqueservice 单例）
--
-- 职责：
--   · 记录"当前线上逻辑模块路径"（current_path），Agent spawn 时按它加载
--   · 维护已注册 Agent 列表
--   · deploy_v2()：切换到 v2 模块并广播 reload
--   · broadcast()：向所有注册 Agent 发 reload（对死掉的地址用 pcall 兜底）
--
-- 注意：广播用 skynet.send（异步、不阻塞热更流程）；对已经退出的 agent 地址，
-- pcall 包住 send，避免"向无效地址投递"崩整个广播。

local skynet = require "skynet"

local agents = {}                        -- 已注册 agent 地址列表
local current_path = "shared.agent_logic"  -- 当前线上逻辑模块路径

local CMD = {}

function CMD.init()
    return true
end

function CMD.register(addr)
    agents[#agents + 1] = addr
    return true
end

function CMD.get_path()
    return current_path
end

-- 向所有注册 agent 广播 reload（切换到 current_path）
function CMD.broadcast()
    local n = 0
    for _, a in ipairs(agents) do
        if pcall(skynet.send, a, "lua", "reload", current_path) then
            n = n + 1
        end
    end
    return true, n
end

-- 模拟"线上部署新版本"：切到 v2 并广播
function CMD.deploy_v2()
    current_path = "shared.agent_logic_v2"
    return CMD.broadcast()
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
