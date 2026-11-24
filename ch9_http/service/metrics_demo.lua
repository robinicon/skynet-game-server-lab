-- service/metrics_demo.lua — 指标提供者示例（模拟业务服务上报）
--
-- /health 不自己产生业务指标，而是调用各业务服务的 `metrics` 命令聚合。
-- 这样新增一个指标来源不需要改 http_mgr。
--
-- 两个命令：
--   metrics          → 正常指标
--   metrics_broken   → 故意抛错（验证 http_mgr 的降级处理）

local skynet  = require "skynet"
local service = require "shared.service"

local handlers = {}

function handlers.metrics()
    return {
        online      = 42,
        qps         = 100,
        pool_free   = 3,
        pool_total  = 8,
        uptime_s    = math.floor(skynet.time()),
    }
end

--- 故意抛错：验证 /health 在 provider 异常时降级而非崩溃
function handlers.metrics_broken()
    error("provider boom")
end

service.start("metrics_demo", handlers)
