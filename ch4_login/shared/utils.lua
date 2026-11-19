-- shared/utils.lua — 通用工具函数
-- 仅依赖 Lua 标准库（时间相关函数显式接收时间值，不隐式依赖 skynet）

local M = {}

--- 安全调用：保留全部返回值
-- 旧实现 `local ok, result = pcall(f, ...)` 只取首个返回值，
-- 多返回值的场景会静默丢数据（修复.md #8 的同源问题）。
-- @return ok boolean, ...
function M.safe_call(fn, ...)
    return pcall(fn, ...)
end

--- 安全调用并折叠为 (ok, result) —— 仅在被调函数只返回单值时使用
function M.safe_call1(fn, ...)
    local r = table.pack(pcall(fn, ...))
    if not r[1] then
        return false, tostring(r[2])
    end
    return true, r[2]
end

--- 耗时（微秒，浮点）
-- 时间值由调用方用 skynet.hpc() 成对取得（纳秒，CLOCK_MONOTONIC）。
-- 不要用 skynet.time()：它的精度只有 10ms（skynet.now() 的 tick 粒度），
-- 会把 p50/p90 全部量化成 0 或 10000，分位数失去意义。
function M.us_between(t0_ns, t1_ns)
    return (t1_ns - t0_ns) / 1000
end

--- 分位数（输入须已升序排列）
-- @param sorted table 升序数组
-- @param p     number 0~1
function M.percentile(sorted, p)
    local n = #sorted
    if n == 0 then
        return 0
    end
    local idx = math.floor(n * p)
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return sorted[idx]
end

--- 均值（微秒数组 → 微秒）
function M.average_us(list)
    local n = #list
    if n == 0 then
        return 0
    end
    local sum = 0
    for i = 1, n do
        sum = sum + list[i]
    end
    return sum / n
end

return M
