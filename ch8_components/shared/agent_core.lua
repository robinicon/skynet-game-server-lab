-- shared/agent_core.lua — Agent 核心：组件注册 / 卸载 / 消息路由
--
-- design.md Phase 5 的映射关系：
--   IAwakeSystem        → 组件的 init(ctx)
--   主动销毁对象的清理   → skynet.exit() 前的 shutdown()（**逆序**调用）
--   组件式编程          → 每个组件一个模块，提供 init / shutdown / handlers
--
-- 三条硬约定：
--   1. 组件只依赖 ctx（共享上下文），不直接互相 require —— 避免循环依赖
--   2. shutdown 严格**逆序**（后加载的先销毁），与构造顺序相反
--   3. 单个组件 init/shutdown 抛错**不影响**其他组件（隔离）
--
-- 消息路由：组件导出 `handlers = { ["bag.add"] = fn, ... }`，
--   core 把所有组件的 handlers 合并成一张路由表，dispatch 时按 cmd 查表。

local error_code = require "shared.error_code"

local M = {}
local Core = {}
Core.__index = Core

--- 创建核心
-- @param opts.ctx      table  共享上下文（uid / db 地址等）
-- @param opts.on_error function(name, phase, err)  组件异常处理回调
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        ctx        = opts.ctx or {},
        on_error   = opts.on_error,
        comps      = {},       -- name → module
        order      = {},       -- 加载顺序（逆序 shutdown 用）
        routes     = {},       -- cmd → { name, fn }
        msg_count  = {},       -- name → 处理过的消息数（拆服务判断依据）
        events     = {},       -- 生命周期事件日志（测试断言用）
    }, Core)
end

--- 加载组件（可运行时动态调用，无需重启 Agent）
-- @param name string
-- @param mod  table   需提供 init(ctx) / shutdown(ctx) / handlers（均可选）
-- @return boolean, err
function Core:load(name, mod)
    if type(name) ~= "string" or type(mod) ~= "table" then
        return false, "invalid component"
    end
    if self.comps[name] then
        return false, "already loaded: " .. name
    end

    self.comps[name] = mod
    self.order[#self.order + 1] = name
    self.msg_count[name] = 0

    -- init：映射 IAwakeSystem
    if type(mod.init) == "function" then
        local ok, err = pcall(mod.init, self.ctx)
        if not ok then
            -- 回滚：init 失败的组件必须完全移除，
            -- 否则它会残留在 order 里（影响 shutdown 顺序与 list()），
            -- 且 comps[name] 指向一个半初始化状态的模块
            self.comps[name] = nil
            for i = #self.order, 1, -1 do
                if self.order[i] == name then
                    table.remove(self.order, i)
                    break
                end
            end
            self.msg_count[name] = nil
            self.events[#self.events + 1] = { phase = "init_error", name = name }
            if self.on_error then self.on_error(name, "init", err) end
            -- 隔离：init 失败不阻断其他组件，但该组件不注册路由
            return false, "init failed: " .. tostring(err)
        end
        self.events[#self.events + 1] = { phase = "init", name = name }
    end

    -- 注册路由
    if type(mod.handlers) == "table" then
        for cmd, fn in pairs(mod.handlers) do
            self.routes[cmd] = { name = name, fn = fn }
        end
    end

    return true
end

--- 卸载组件（运行时动态移除）
function Core:unload(name)
    local mod = self.comps[name]
    if not mod then
        return false, "not loaded: " .. name
    end

    if type(mod.shutdown) == "function" then
        local ok, err = pcall(mod.shutdown, self.ctx)
        if not ok and self.on_error then
            self.on_error(name, "shutdown", err)
        end
    end
    self.events[#self.events + 1] = { phase = "shutdown", name = name }

    -- 摘除路由
    if type(mod.handlers) == "table" then
        for cmd in pairs(mod.handlers) do
            if self.routes[cmd] and self.routes[cmd].name == name then
                self.routes[cmd] = nil
            end
        end
    end

    self.comps[name] = nil
    for i, n in ipairs(self.order) do
        if n == name then
            table.remove(self.order, i)
            break
        end
    end
    return true
end

--- 消息路由
-- @return code, ...
function Core:dispatch(cmd, ...)
    local r = self.routes[cmd]
    if not r then
        return error_code.ERR_INVALID_ARG, "no handler for cmd: " .. tostring(cmd)
    end
    self.msg_count[r.name] = (self.msg_count[r.name] or 0) + 1
    -- 必须用 table.pack：handler 可能返回 (code, data...)，
    -- `local ok, res = pcall(...)` 只拿得到第一个返回值（ch4 修复.md #8 同源坑）
    local p = table.pack(pcall(r.fn, self.ctx, ...))
    if not p[1] then
        if self.on_error then self.on_error(r.name, "dispatch", p[2]) end
        return error_code.ERR_INTERNAL, tostring(p[2])
    end
    if p.n == 1 then
        return error_code.OK
    end
    return table.unpack(p, 2, p.n)
end

--- 全部关闭：**严格逆序**
function Core:shutdown()
    local errs = {}
    for i = #self.order, 1, -1 do
        local name = self.order[i]
        local mod = self.comps[name]
        if mod and type(mod.shutdown) == "function" then
            local ok, err = pcall(mod.shutdown, self.ctx)
            if not ok then
                errs[#errs + 1] = string.format("%s: %s", name, tostring(err))
                if self.on_error then self.on_error(name, "shutdown", err) end
            end
        end
        self.events[#self.events + 1] = { phase = "shutdown", name = name }
    end
    self.comps = {}
    self.order = {}
    self.routes = {}
    return #errs == 0, errs
end

--- 组件是否已加载
function Core:has(name)
    return self.comps[name] ~= nil
end

--- 加载顺序快照
function Core:list()
    local r = {}
    for i, n in ipairs(self.order) do r[i] = n end
    return r
end

--- 生命周期事件（测试断言用）
function Core:event_log()
    return self.events
end

--- 统计：含"是否建议拆为独立服务"
-- design.md：战斗组件消息量高时拆为独立服务（预留判断阈值）
function Core:stats(threshold)
    threshold = threshold or tonumber(os.getenv("CH8_SPLIT_THRESHOLD")) or 1000
    local list = {}
    for _, name in ipairs(self.order) do
        local n = self.msg_count[name] or 0
        list[#list + 1] = {
            name = name,
            messages = n,
            split_threshold = threshold,
            should_split = n >= threshold,
        }
    end
    return {
        components = list,
        total_messages = (function()
            local s = 0
            for _, c in ipairs(list) do s = s + c.messages end
            return s
        end)(),
        threshold = threshold,
    }
end

return M
