-- test/stress_center.lua — T5/T6：center 单点吞吐压测（不走网络）
--
-- 运行方式：make stress
-- 说明：本用例测的是 center 单服务的串行处理能力，**不含 TCP/协议/agent 开销**。
--       真实端到端能力请看 stress_e2e.lua，两者不要互相替代。
--
-- 改进点（相对旧 stress_1000.lua）：
--   1. 延迟统计改微秒（旧版毫秒取整导致 p50/p90 全部为 0）
--   2. 批次等待加超时上限（旧版无上限，协程异常时会永久挂死）
--   3. 账号预注册分页（旧版单条消息内循环 1000 次，长时间独占 center）
--   4. 压测收尾清理在线状态
--   5. 不再 os.exit，返回 {pass, fail, summary} 由 main 汇总

local skynet     = require "skynet"
local error_code = require "shared.error_code"
local utils      = require "shared.utils"

local REPORT_FILE = "log/ch4-stress_center/report.json"
local COUNT       = tonumber(os.getenv("CH4_STRESS_COUNT")) or 1000
local BATCH_SIZE  = 100
local SAMPLE_SIZE = 10
local PASSWORD    = "pass123"
local WAIT_TICKS  = 1000     -- 单批最长等待 1000 tick（10 秒），超时判失败

local out = {}

local function emit(line)
    out[#out + 1] = line
    io.write(line .. "\n")
end

local function run(center)
    if not center then
        emit("ERROR: center addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR: no center" }
    end

    emit(string.format("\n=== T5 Stress (center only): %d logins (batch=%d) ===", COUNT, BATCH_SIZE))

    -- 0. 重置在线状态 + 预注册账号池（register_many 幂等，重复运行不会重复建号）
    pcall(skynet.call, center, "lua", "logout_all")
    local ok_reg, registered = pcall(skynet.call, center, "lua", "register_many", "bot", COUNT, PASSWORD)
    if not ok_reg or type(registered) ~= "number" then
        emit(string.format("ERROR: register_many failed (%s)", tostring(registered)))
        return { pass = 0, fail = 1, summary = table.concat(out, "\n") }
    end
    if registered < COUNT then
        emit(string.format("ERROR: registered %d < %d", registered, COUNT))
        return { pass = 0, fail = 1, summary = table.concat(out, "\n") }
    end
    emit(string.format("  registered %d bot accounts", registered))

    -- 1. 分批并发登录
    local latencies = {}
    local errors    = {}
    local success, fail_n = 0, 0
    local samples   = {}

    local total_start = skynet.hpc()
    local completed  = 0
    local timed_out  = false
    local total_batches = math.ceil(COUNT / BATCH_SIZE)

    for batch_idx = 0, total_batches - 1 do
        local start_i = batch_idx * BATCH_SIZE + 1
        local end_i   = math.min(start_i + BATCH_SIZE - 1, COUNT)

        for i = start_i, end_i do
            local bot = string.format("bot%d", i)
            skynet.fork(function()
                local t0 = skynet.hpc()
                local ok, resp = pcall(skynet.call, center, "lua", "login", bot, PASSWORD)
                local us = math.floor(utils.us_between(t0, skynet.hpc()))

                if ok and type(resp) == "table" and resp[1] == error_code.OK then
                    success = success + 1
                    latencies[#latencies + 1] = us
                    if #samples < SAMPLE_SIZE then
                        samples[#samples + 1] = { name = bot, uid = resp[2], token = resp[3] }
                    end
                else
                    fail_n = fail_n + 1
                    local err_val = (ok and type(resp) == "table" and resp[1]) or "CALL_ERROR"
                    local key = error_code.desc(tonumber(err_val) or -99)
                    errors[key] = (errors[key] or 0) + 1
                end
                completed = completed + 1
            end)
        end

        -- 等待本批完成：10ms 轮询 + 超时上限（旧版无上限，异常时会挂死）
        local waited = 0
        while completed < end_i and waited < WAIT_TICKS do
            skynet.sleep(1)
            waited = waited + 1
        end
        if completed < end_i then
            timed_out = true
            emit(string.format("  ERROR: batch %d timed out (completed=%d/%d)",
                batch_idx + 1, completed, end_i))
            break
        end
        if (batch_idx + 1) % 2 == 0 then
            emit(string.format("  progress: %d/%d ok=%d fail=%d", completed, COUNT, success, fail_n))
        end
    end

    local total_us = math.floor(utils.us_between(total_start, skynet.hpc()))

    -- 2. 统计
    table.sort(latencies)
    local n = #latencies
    emit("\n" .. string.rep("=", 60))
    emit(string.format("  Total requests:   %d", COUNT))
    emit(string.format("  Success:          %d (%.2f%%)", success, success / COUNT * 100))
    emit(string.format("  Failed:           %d (%.2f%%)", fail_n, fail_n / COUNT * 100))
    emit(string.format("  Total time:       %.1f ms", total_us / 1000))
    emit(string.format("  Throughput:       %.1f req/s", total_us > 0 and COUNT / (total_us / 1000000) or 0))
    emit(string.format("  Avg latency:      %.1f us", utils.average_us(latencies)))
    emit(string.format("  Min latency:      %d us", n > 0 and latencies[1] or 0))
    emit(string.format("  Max latency:      %d us", n > 0 and latencies[n] or 0))
    emit(string.format("  P50 latency:      %d us", utils.percentile(latencies, 0.50)))
    emit(string.format("  P90 latency:      %d us", utils.percentile(latencies, 0.90)))
    emit(string.format("  P99 latency:      %d us", utils.percentile(latencies, 0.99)))
    if next(errors) then
        emit("  Error distribution:")
        for code, cnt in pairs(errors) do
            emit(string.format("    %s: %d", tostring(code), cnt))
        end
    end

    -- 3. T6: Token 重连验证（抽样）
    emit("\n=== T6: Token reconnect verification ===")
    local reconnected = 0
    for _, s in ipairs(samples) do
        local step_ok = false
        local ok1, rv1 = pcall(skynet.call, center, "lua", "verify_token", s.token)
        if ok1 and rv1 and rv1[1] == error_code.OK and rv1[2] == s.uid then
            -- 免密重连：用旧 token 换发新 token
            skynet.call(center, "lua", "logout", s.uid)
            local ok2, rv2 = pcall(skynet.call, center, "lua", "login_by_token", s.token)
            if ok2 and rv2 and rv2[1] == error_code.OK and rv2[2] == s.uid then
                local ok3, rv3 = pcall(skynet.call, center, "lua", "verify_token", rv2[3])
                step_ok = ok3 and rv3 and rv3[1] == error_code.OK and rv3[2] == s.uid
            end
        end
        if step_ok then
            reconnected = reconnected + 1
        end
    end
    emit(string.format("  Reconnect verify: %d/%d passed", reconnected, #samples))

    -- 4. 收尾：清理在线状态（旧版压测后残留 1000 条 online 记录）
    local ok_c, cleared = pcall(skynet.call, center, "lua", "logout_all")
    local ok_list, online_count = pcall(skynet.call, center, "lua", "online_count")
    emit(string.format("  Cleanup: cleared=%s online_after=%s",
        tostring(ok_c and cleared), tostring(ok_list and online_count)))
    emit(string.rep("=", 60))

    -- 5. JSON 报告
    local err_parts = {}
    for code, cnt in pairs(errors) do
        err_parts[#err_parts + 1] = string.format("\"%s\":%d", tostring(code), cnt)
    end
    local report = string.format(
        [[{
    "timestamp": "%s",
    "total": %d,
    "success": %d,
    "failed": %d,
    "success_rate": %.2f,
    "total_time_ms": %.1f,
    "throughput_qps": %.1f,
    "avg_latency_us": %.1f,
    "min_latency_us": %d,
    "max_latency_us": %d,
    "p50_latency_us": %d,
    "p90_latency_us": %d,
    "p99_latency_us": %d,
    "errors": {%s},
    "reconnect_verify": "%d/%d"
}]],
        os.date("%Y-%m-%dT%H:%M:%S"),
        COUNT, success, fail_n, success / COUNT * 100,
        total_us / 1000,
        total_us > 0 and COUNT / (total_us / 1000000) or 0,
        utils.average_us(latencies),
        n > 0 and latencies[1] or 0,
        n > 0 and latencies[n] or 0,
        utils.percentile(latencies, 0.50),
        utils.percentile(latencies, 0.90),
        utils.percentile(latencies, 0.99),
        table.concat(err_parts, ","),
        reconnected, #samples
    )
    local f = io.open(REPORT_FILE, "w")
    if f then
        f:write(report)
        f:close()
        emit(string.format("  Report written to: %s", REPORT_FILE))
    else
        emit(string.format("  WARNING: cannot write report file: %s", REPORT_FILE))
    end

    local all_pass = (fail_n == 0 and not timed_out and reconnected == #samples)
    emit(all_pass and "  ALL TESTS PASSED" or "  TESTS FAILED")

    return {
        pass    = all_pass and 1 or 0,
        fail    = all_pass and 0 or 1,
        summary = table.concat(out, "\n"),
    }
end

local handlers = {}
function handlers.run(center)
    return run(center)
end

require "shared.service".start("stress_center", handlers)

return handlers
