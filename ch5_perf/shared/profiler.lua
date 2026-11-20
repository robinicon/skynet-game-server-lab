-- shared/profiler.lua — 采样式 CPU profiler（基于 debug.sethook）
--
-- 为什么需要它：
--   skynet 内置的 profile 只统计**服务级**累计 CPU（skynet.stat("cpu")），
--   拿不到函数级热点。design.md Phase 2 要求"先 profiling 确认瓶颈"，
--   所以必须有一个能定位到函数的工具。
--
-- 原理：
--   debug.sethook(hook, "", count) —— 每执行 count 条 VM 指令触发一次 hook，
--   hook 里用 debug.getinfo 取当前函数名/源/行号并累计。
--   采样精度与开销成反比：count 越小越准但越慢。
--
-- ⚠️ 重要限制（Lua 5.2+）：
--   debug hook 是 **per-coroutine** 的。sethook 只影响当前协程，
--   负载代码一旦 yield 切换到其他协程，采样就停了。
--   因此本 profiler 只适用于**不 yield 的同步代码块**（基准循环、纯计算），
--   这正是 ch5 的使用场景。要 profile 含 yield 的异步流程，
--   应在每个协程内分别 start/stop，或改用服务级 skynet.stat("cpu")。
--
-- 用法：
--   profiler.start(1000)      -- 每 1000 条指令采样一次
--   ... 同步负载 ...
--   local r = profiler.stop()
--   profiler.report(r, 10)    -- 打印 Top 10

local M = {}

local active      = false
local samples     = nil     -- func → { name, source, line, count }
local total_count = 0
local start_ns    = 0

local function hook()
    local info = debug.getinfo(2, "nSf")
    if not info then return end
    local f = info.func
    if not f then return end

    local e = samples[f]
    if e then
        e.count = e.count + 1
    else
        samples[f] = {
            name   = info.name or "?",
            source = info.short_src or "?",
            line   = info.linedefined or 0,
            count  = 1,
        }
    end
    total_count = total_count + 1
end

--- 开始采样
-- @param interval number 每多少条 VM 指令采样一次（默认 1000）
function M.start(interval)
    if active then
        return false
    end
    interval = tonumber(interval) or 1000
    samples = {}
    total_count = 0
    start_ns = os.clock()
    active = true
    debug.sethook(hook, "", interval)
    return true
end

--- 停止采样
-- @return { total, elapsed_cpu_s, list = { {name, source, line, count, pct} ... } }
function M.stop()
    if not active then
        return nil
    end
    debug.sethook()
    active = false

    local elapsed = os.clock() - start_ns

    local list = {}
    for f, e in pairs(samples) do
        e.pct = total_count > 0 and (e.count / total_count * 100) or 0
        list[#list + 1] = e
    end
    table.sort(list, function(a, b) return a.count > b.count end)

    local r = { total = total_count, elapsed_cpu_s = elapsed, list = list }
    samples = nil
    return r
end

--- 是否正在采样
function M.is_active()
    return active
end

--- 打印热点报告
function M.report(r, topn)
    if not r then return "" end
    topn = topn or 10
    local out = {}
    out[#out + 1] = string.format("--- profiler: %d samples, cpu %.3fs ---",
        r.total, r.elapsed_cpu_s)
    out[#out + 1] = string.format("%-6s %-8s %s", "PCT%", "SAMPLES", "FUNCTION")
    for i = 1, math.min(topn, #r.list) do
        local e = r.list[i]
        local label = e.name
        if label == "?" or label == nil or label == "" then
            label = "anonymous"
        end
        out[#out + 1] = string.format("%-6.2f %-8d %s (%s:%d)",
            e.pct, e.count, label, e.source, e.line)
    end
    local s = table.concat(out, "\n")
    print(s)
    return s
end

--- 找出指定名称的函数占比（用于自动化断言）
-- @return pct number, entry table
function M.share_of(r, name)
    if not r then return 0, nil end
    for _, e in ipairs(r.list) do
        if e.name == name then
            return e.pct, e
        end
    end
    return 0, nil
end

return M
