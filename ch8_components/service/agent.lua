-- service/agent.lua — 组件式 Agent
--
-- 启动时加载基础组件（bag / skill / quest），运行期可动态注入/卸载。
-- 所有客户端消息经 core:dispatch 路由到具体组件。
-- skynet.exit() 之前必须调用 core:shutdown()（逆序清理）。

local skynet   = require "skynet"
local service  = require "shared.service"
local core_mod = require "shared.agent_core"

local core = nil
local ctx  = nil

-- 启动时加载的组件（顺序即 init 顺序，shutdown 时逆序）
local BASE_COMPONENTS = { "bag", "skill", "quest" }

local handlers = {}

function handlers.init(uid, opts)
    opts = opts or {}
    ctx = {
        uid = uid,
        now = skynet.time(),
        bag_capacity = opts.bag_capacity,
    }

    core = core_mod.new({
        ctx = ctx,
        on_error = function(name, phase, err)
            -- 组件异常不能打挂 Agent：记录后继续
            skynet.error(string.format("[agent] component %s %s error: %s",
                tostring(name), tostring(phase), tostring(err)))
        end,
    })
    ctx.core = core      -- 供组件做跨组件通信（走路由，不直接 require）

    local loaded = {}
    for _, name in ipairs(BASE_COMPONENTS) do
        local ok, mod = pcall(require, "shared.component_" .. name)
        if not ok then
            skynet.error(string.format("[agent] component %s not found: %s", name, tostring(mod)))
        else
            local ok2, err = core:load(name, mod)
            if not ok2 then
                skynet.error(string.format("[agent] load %s failed: %s", name, tostring(err)))
            else
                loaded[#loaded + 1] = name
            end
        end
    end
    return loaded
end

--- 客户端消息路由
function handlers.client(cmd, ...)
    if not core then
        return require("shared.error_code").ERR_INTERNAL, "agent not initialized"
    end
    return core:dispatch(cmd, ...)
end

--- 运行时动态注入组件（不重启 Agent）
function handlers.load(name)
    if not core then return false, "not initialized" end
    local ok, mod = pcall(require, "shared.component_" .. tostring(name))
    if not ok then
        return false, "no such component: " .. tostring(name)
    end
    return core:load(name, mod)
end

function handlers.unload(name)
    if not core then return false, "not initialized" end
    return core:unload(name)
end

function handlers.list()
    return core and core:list() or {}
end

function handlers.has(name)
    return core and core:has(name) or false
end

function handlers.events()
    return core and core:event_log() or {}
end

function handlers.stats(threshold)
    return core and core:stats(threshold) or nil
end

--- 退出：先逆序 shutdown 所有组件
function handlers.exit()
    if not core then return true end
    local ok, errs = core:shutdown()
    return ok, errs
end

service.start("agent", handlers)
