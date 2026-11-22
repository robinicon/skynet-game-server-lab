-- shared/connpool.lua — 连接池
--
-- 职责：
--   1. 复用连接，避免每次查询都建连（TCP + 认证握手）
--   2. 无空闲连接时挂起等待（而不是报错或无限创建）
--   3. 动态扩容：持续有等待者时增加连接，直到 hard_max
--   4. 定时收缩：长期空闲时释放多余连接，直到 min
--
-- 等待/唤醒用 skynet.wait / skynet.wakeup（token = 协程对象），
-- 不用轮询 —— 轮询会引入 10ms 粒度的固定延迟。

local skynet = require "skynet"

local M = {}
local Pool = {}
Pool.__index = Pool

--- @param opts.name     string
--- @param opts.factory  function() -> conn     新建连接
--- @param opts.closer   function(conn)        销毁连接（可选）
--- @param opts.min      number  最小保持数（默认 1）
--- @param opts.max      number  常规上限（默认 8）
--- @param opts.hard_max number  扩容硬上限（默认 32）
function M.new(opts)
    local self = setmetatable({
        name     = opts.name or "pool",
        factory  = opts.factory,
        closer   = opts.closer,
        min      = opts.min or 1,
        max      = opts.max or 8,
        hard_max = opts.hard_max or 32,

        free     = {},
        total    = 0,
        waiters  = {},
        stat     = { created = 0, closed = 0, acquire = 0, waited = 0, peak_total = 0 },
    }, Pool)

    for _ = 1, self.min do
        self.free[#self.free + 1] = self:_create()
    end
    return self
end

function Pool:_create()
    self.total = self.total + 1
    self.stat.created = self.stat.created + 1
    if self.total > self.stat.peak_total then
        self.stat.peak_total = self.total
    end
    return self.factory()
end

function Pool:_close(conn)
    if self.closer then
        pcall(self.closer, conn)
    end
    self.total = self.total - 1
    self.stat.closed = self.stat.closed + 1
end

--- 取连接（无空闲则挂起等待）
function Pool:acquire()
    self.stat.acquire = self.stat.acquire + 1

    local conn = table.remove(self.free)
    if conn then
        return conn
    end

    -- 常规上限内可直接新建
    if self.total < self.max then
        return self:_create()
    end

    -- 有等待者说明负载高 → 允许扩容到 hard_max
    if self.total < self.hard_max then
        return self:_create()
    end

    -- 真的满了：挂起等待
    local co = coroutine.running()
    self.waiters[#self.waiters + 1] = co
    self.stat.waited = self.stat.waited + 1
    skynet.wait(co)
    -- 被唤醒时 release 已经把连接放回了 free
    return table.remove(self.free)
end

--- 归还连接
function Pool:release(conn)
    if not conn then return end

    if #self.waiters > 0 then
        local co = table.remove(self.waiters, 1)
        -- 直接交给等待者：先入 free 再唤醒，唤醒方从 free 取
        self.free[#self.free + 1] = conn
        skynet.wakeup(co)
        return
    end

    self.free[#self.free + 1] = conn
end

--- 定时收缩：空闲数超过 min 时释放多余连接
function Pool:shrink()
    local released = 0
    while #self.free > self.min do
        local conn = table.remove(self.free)
        self:_close(conn)
        released = released + 1
    end
    return released
end

function Pool:stats()
    return {
        name      = self.name,
        free      = #self.free,
        total     = self.total,
        min       = self.min,
        max       = self.max,
        hard_max  = self.hard_max,
        waiting   = #self.waiters,
        created   = self.stat.created,
        closed    = self.stat.closed,
        acquire   = self.stat.acquire,
        waited    = self.stat.waited,
        peak_total = self.stat.peak_total,
    }
end

return M
