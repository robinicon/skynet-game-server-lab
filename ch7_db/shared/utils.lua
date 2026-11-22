-- shared/utils.lua — 通用工具函数
-- 仅依赖 Lua 标准库。时间值必须由调用方用 skynet.hpc() 成对取得。

local M = {}

function M.safe_call(fn, ...)
    return pcall(fn, ...)
end

--- 耗时（微秒，浮点）
-- 不要用 skynet.time()：精度只有 10ms，会把分位数量化成 0 或 10000
function M.us_between(t0_ns, t1_ns)
    return (t1_ns - t0_ns) / 1000
end

--- 分位数（输入须已升序）
function M.percentile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    local idx = math.floor(n * p)
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return sorted[idx]
end

function M.average_us(list)
    local n = #list
    if n == 0 then return 0 end
    local sum = 0
    for i = 1, n do sum = sum + list[i] end
    return sum / n
end

--- 保留 n 位小数（避免 string.format("%d", float) 在 Lua 5.4+ 抛错）
function M.fmt_num(v, n)
    n = n or 2
    return string.format("%." .. tostring(n) .. "f", tonumber(v) or 0)
end

--- 千分位（便于读大数字）
function M.comma(v)
    local s = tostring(math.floor(tonumber(v) or 0))
    local left, num, right = s:match("([^%d]*%d)(%d*)(.-)")
    if not left then return s end
    return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

return M
