-- shared/service.lua — 统一服务骨架
-- 依赖：skynet + shared/error_code
--
-- 解决的问题：
--   1. center / login / gate 各自重复实现 `if-elseif` 命令链与 reply 闭包
--   2. handler 抛异常时调用方永久挂起（无回复）
--   3. send（session == 0）被误回复
--
-- 约定：handler 直接 return 结果，由骨架负责 retpack；
--       handler 抛异常 → 统一返回 ERR_INTERNAL + 错误信息，不会挂死调用方。

local skynet     = require "skynet"
local error_code = require "shared.error_code"

local M = {}

--- 启动一个标准服务
-- @param name     string   服务名（用于日志前缀）
-- @param handlers table    { cmd = function(...) -> ... }
-- @param opts     table    { on_init = function(), on_unknown = function(cmd, ...) }
function M.start(name, handlers, opts)
    opts = opts or {}

    skynet.start(function()
        if opts.on_init then
            opts.on_init()
        end

        skynet.dispatch("lua", function(_, session, cmd, ...)
            local f = handlers[cmd]
            if not f then
                skynet.error(string.format("[%s] unknown cmd: %s", name, tostring(cmd)))
                if opts.on_unknown then
                    local r = table.pack(pcall(opts.on_unknown, cmd, ...))
                    if session ~= 0 then
                        if r[1] then
                            skynet.retpack(table.unpack(r, 2, r.n))
                        else
                            skynet.retpack(error_code.ERR_INTERNAL, "unknown cmd handler error")
                        end
                    end
                elseif session ~= 0 then
                    skynet.retpack(error_code.ERR_INTERNAL, "unknown cmd: " .. tostring(cmd))
                end
                return
            end

            local r = table.pack(pcall(f, ...))
            if not r[1] then
                skynet.error(string.format("[%s] cmd %s error: %s", name, tostring(cmd), tostring(r[2])))
                if session ~= 0 then
                    skynet.retpack(error_code.ERR_INTERNAL, "cmd error: " .. tostring(r[2]))
                end
                return
            end

            -- send（session == 0）不需要、也不能回复
            if session ~= 0 then
                skynet.retpack(table.unpack(r, 2, r.n))
            end
        end)
    end)
end

return M
