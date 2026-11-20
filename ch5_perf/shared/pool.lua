-- shared/pool.lua — 通用业务对象池
--
-- 设计前提（design.md Phase 2）：
--   **先 profiling 确认瓶颈，再池化。** 池化不是免费的：
--     池化收益 = 省下的构造成本 − (取用成本 + 归还成本)
--   对小对象，后者可能大于前者 —— 实测 packet（5 字段）strict 模式约 0.81x（即慢约 19%，见 bench 场景 A）。
--   所以池化适用于"构造成本高"或"结构大"的对象，不是所有对象。
--
-- 三档模式（mode）：
--   strict  —— 完整检测（foreign / double-free / reset 失败）+ 完整统计。开发测试用。
--   fast    —— 去掉 owned 检测，保留核心统计。生产推荐。
--   bare    —— 无任何检测与统计，纯 free-list。极限性能，丢失可观测性。
--
-- 实现要点：**热路径状态放在闭包 upvalue（Lua 寄存器）而非 table 字段**。
--   table 字段每次访问是一次哈希查找；upvalue 是寄存器访问。
--   这是 Lua 中把热路径从"表驱动"改成"闭包驱动"的经典优化，
--   实测能把 get/put 的成本降到接近裸数组操作。
--
-- 五条硬约束：
--   1. 池满不阻塞 —— put 时超限直接丢弃，绝不等待
--   2. 拒绝 double-free（strict）
--   3. 拒绝 foreign object（strict）
--   4. reset 失败不入库（strict）
--   5. 借出不还可被 GC —— owned 是弱 key 表
--
-- 用法：
--   local p = pool.new({
--       name = "packet", mode = "fast",
--       factory = function() return {} end,
--       reset = function(o) o.x = nil end, max = 1024, prewarm = 32,
--   })
--   local o = p:get(); ...; p:put(o)

local error_code = require "shared.error_code"

local M = {}

--- 创建池
-- @param opts.name     string   池名
-- @param opts.factory  function 构造函数（必填）
-- @param opts.reset    function 归还清理函数（建议提供）
-- @param opts.max      number   池上限（默认 1024）
-- @param opts.prewarm  number   预热数量（默认 0）
-- @param opts.mode     string   "strict" | "fast" | "bare"（默认 "strict"）
function M.new(opts)
    assert(type(opts) == "table", "pool.new: opts must be a table")
    assert(type(opts.factory) == "function", "pool.new: factory must be a function")

    local factory = opts.factory
    local reset   = opts.reset
    local max     = opts.max or 1024
    local name    = opts.name or "anon"
    local mode    = opts.mode or "strict"

    -- 热路径状态（闭包 upvalue = 寄存器访问）
    local free   = {}
    local n_free = 0
    local created, reused, borrowed, peak = 0, 0, 0, 0
    local rej_foreign, rej_double, discarded, reset_failed = 0, 0, 0, 0

    local owned = nil
    if mode == "strict" then
        owned = setmetatable({}, { __mode = "k" })   -- 弱 key：借出不还可被 GC
    end

    local api = { name = name, max = max, mode = mode }

    -- ============ strict：完整检测 + 完整统计 ============
    if mode == "strict" then
        api.get = function(_)
            local obj
            if n_free > 0 then
                obj = free[n_free]
                free[n_free] = nil
                n_free = n_free - 1
                reused = reused + 1
            else
                obj = factory()
                created = created + 1
            end
            owned[obj] = "out"
            borrowed = borrowed + 1
            if borrowed > peak then peak = borrowed end
            return obj
        end

        api.put = function(_, obj)
            if obj == nil then
                return false, error_code.ERR_INVALID_ARG
            end
            local st = owned[obj]
            if st == nil then
                rej_foreign = rej_foreign + 1
                return false, error_code.ERR_FOREIGN_OBJECT
            end
            if st ~= "out" then
                rej_double = rej_double + 1
                return false, error_code.ERR_DOUBLE_FREE
            end
            borrowed = borrowed - 1

            if n_free >= max then
                owned[obj] = nil
                discarded = discarded + 1
                return false, error_code.ERR_POOL_FULL
            end

            if reset then
                local ok = pcall(reset, obj)
                if not ok then
                    owned[obj] = nil
                    reset_failed = reset_failed + 1
                    return false, error_code.ERR_RESET_FAILED
                end
            end

            n_free = n_free + 1
            free[n_free] = obj
            owned[obj] = true
            return true, error_code.OK
        end

    -- ============ fast：去掉 owned 检测，保留核心统计 ============
    elseif mode == "fast" then
        api.get = function(_)
            if n_free > 0 then
                local obj = free[n_free]
                free[n_free] = nil
                n_free = n_free - 1
                reused = reused + 1
                borrowed = borrowed + 1
                if borrowed > peak then peak = borrowed end
                return obj
            end
            created = created + 1
            borrowed = borrowed + 1
            if borrowed > peak then peak = borrowed end
            return factory()
        end

        api.put = function(_, obj)
            if obj == nil then
                return false, error_code.ERR_INVALID_ARG
            end
            borrowed = borrowed - 1
            if n_free >= max then
                discarded = discarded + 1
                return false, error_code.ERR_POOL_FULL
            end
            if reset then reset(obj) end
            n_free = n_free + 1
            free[n_free] = obj
            return true, error_code.OK
        end

    -- ============ bare：纯 free-list，零检测零统计 ============
    else
        api.get = function(_)
            if n_free > 0 then
                local obj = free[n_free]
                free[n_free] = nil
                n_free = n_free - 1
                return obj
            end
            return factory()
        end

        api.put = function(_, obj)
            if obj == nil then return false end
            if n_free >= max then return false end
            if reset then reset(obj) end
            n_free = n_free + 1
            free[n_free] = obj
            return true
        end
    end

    --- 预热
    api.prewarm = function(_, n)
        n = tonumber(n) or 0
        local added = 0
        for _ = 1, n do
            if n_free >= max then break end
            local obj = factory()
            created = created + 1
            n_free = n_free + 1
            free[n_free] = obj
            if owned then owned[obj] = true end
            added = added + 1
        end
        return added
    end

    --- 清空
    api.clear = function(_)
        local n = n_free
        for i = 1, n do
            if owned then owned[free[i]] = nil end
            free[i] = nil
        end
        n_free = 0
        return n
    end

    --- 统计快照
    api.stats = function(_)
        return {
            name    = name,
            mode    = mode,
            size    = n_free,
            max     = max,
            created = created,
            reused  = reused,
            borrowed = borrowed,
            peak     = peak,
            rejected_foreign = rej_foreign,
            rejected_double  = rej_double,
            discarded = discarded,
            reset_failed = reset_failed,
        }
    end

    --- 复用率
    api.reuse_rate = function(_)
        local total = reused + created
        if total == 0 then return 0 end
        return reused / total
    end

    -- 当前空闲数（热路径读取，避免构造 stats 表）
    api.size = function(_) return n_free end

    if opts.prewarm and opts.prewarm > 0 then
        -- 必须用 `:` 调用：闭包首参是 self（与 api.get/put 保持同一约定）
        api:prewarm(opts.prewarm)
    end

    return api
end

return M
