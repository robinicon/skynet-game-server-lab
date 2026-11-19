-- test/stress_e2e.lua — T8：端到端压测（TCP + sproto + agent 创建）
--
-- 运行方式：make stress-e2e
-- 与 stress_center 的区别：本用例走完整链路
--   TCP connect → gate 握手 → login 认证 → center 签发 → agent 服务创建 → login_resp
-- 这是唯一可以对外引用的"登录性能"数字。
--
-- 改进点：微秒统计、批次超时上限、压测后清理、返回结构化结果

local skynet     = require "skynet"
local error_code = require "shared.error_code"
local utils      = require "shared.utils"
local robot      = require "test.robot"
local proto      = require "proto.proto"
local conf       = require "runtime"

local REPORT_FILE = "log/ch4-stress_e2e/report.json"
local COUNT       = tonumber(os.getenv("CH4_E2E_COUNT")) or 1000
local BATCH_SIZE  = 100
local PING_SAMPLE = 10
local PASSWORD    = "pass123"
local WAIT_TICKS  = 3000    -- 单批最长等待 30 秒

local out = {}

local function emit(line)
    out[#out + 1] = line
    io.write(line .. "\n")
end

local function run(center, gate)
    if not center then
        emit("ERROR: center addr not provided")
        return { pass = 0, fail = 1, summary = "ERROR: no center" }
    end

    local addr = conf.gate_address or "127.0.0.1"
    local port = tonumber(conf.gate_port) or 8888
    if addr == "0.0.0.0" then addr = "127.0.0.1" end

    emit(string.format("\n=== T8 End-to-end Stress: %d TCP logins via %s:%d (batch=%d) ===",
        COUNT, addr, port, BATCH_SIZE))

    -- 0. 预注册
    local ok_reg, registered = pcall(skynet.call, center, "lua", "register_many", "ebot", COUNT, PASSWORD)
    if not ok_reg or type(registered) ~= "number" or registered < COUNT then
        emit(string.format("ERROR: register_many failed (%s)", tostring(registered)))
        return { pass = 0, fail = 1, summary = table.concat(out, "\n") }
    end
    emit(string.format("  registered %d accounts", registered))

    -- 1. 分批并发
    local latencies, errors = {}, {}
    local connect_us, login_us = {}, {}   -- 分段耗时：定位瓶颈在连接建立还是登录处理
    local ping_us   = {}                  -- 业务往返耗时：区分链路延迟与登录逻辑开销
    local ping_rounds = {}                -- 第 1/2/3 次往返分别的耗时（判断冷唤醒 vs 稳态）
    local success, fail_n = 0, 0
    local connect_fail = 0
    local ping_ok = 0
    local completed = 0
    local timed_out = false
    local total_start = skynet.hpc()
    local total_batches = math.ceil(COUNT / BATCH_SIZE)

    for batch_idx = 0, total_batches - 1 do
        local start_i = batch_idx * BATCH_SIZE + 1
        local end_i   = math.min(start_i + BATCH_SIZE - 1, COUNT)

        for i = start_i, end_i do
            local bot = string.format("ebot%d", i)
            skynet.fork(function()
                local t0 = skynet.hpc()
                local fd = robot.connect(addr, port)
                local t1 = skynet.hpc()
                if not fd then
                    connect_fail = connect_fail + 1
                    fail_n = fail_n + 1
                    errors["CONNECT_FAIL"] = (errors["CONNECT_FAIL"] or 0) + 1
                    completed = completed + 1
                    return
                end
                connect_us[#connect_us + 1] = math.floor(utils.us_between(t0, t1))

                local resp, err = robot.login(fd, bot, PASSWORD)
                local t2 = skynet.hpc()
                login_us[#login_us + 1] = math.floor(utils.us_between(t1, t2))
                local us = math.floor(utils.us_between(t0, t2))

                if resp and resp.code == error_code.OK then
                    success = success + 1
                    latencies[#latencies + 1] = us
                    -- 抽样做一次业务往返，验证 agent 已接管
                    if success <= PING_SAMPLE then
                        -- 连续 3 次往返：区分"冷唤醒"与"稳态调度"开销
                        local last_ok = false
                        for round = 1, 3 do
                            local pt0 = skynet.hpc()
                            local body = robot.request(fd, 1, proto.encode("Ping", { timestamp = 1 }), 1 + round)
                            local content = robot.unpack(body)
                            ping_us[#ping_us + 1] = math.floor(utils.us_between(pt0, skynet.hpc()))
                            if round == 1 then
                                ping_rounds[1] = (ping_rounds[1] or 0) + (ping_us[#ping_us])
                            elseif round == 2 then
                                ping_rounds[2] = (ping_rounds[2] or 0) + (ping_us[#ping_us])
                            else
                                ping_rounds[3] = (ping_rounds[3] or 0) + (ping_us[#ping_us])
                            end
                            last_ok = content ~= nil and #content > 1 and string.byte(content, 1) == 1
                        end
                        if last_ok then
                            ping_ok = ping_ok + 1
                        end
                    end
                else
                    fail_n = fail_n + 1
                    local key = resp and error_code.desc(resp.code) or ("NET_" .. tostring(err))
                    errors[key] = (errors[key] or 0) + 1
                end
                robot.close(fd)
                completed = completed + 1
            end)
        end

        local batch_start = skynet.hpc()
        local waited = 0
        while completed < end_i and waited < WAIT_TICKS do
            skynet.sleep(1)
            waited = waited + 1
        end
        if os.getenv("CH4_E2E_DEBUG") == "1" then
            emit(string.format("  [debug] batch %d wall=%.1f ms waited=%d completed=%d",
                batch_idx + 1, utils.us_between(batch_start, skynet.hpc()) / 1000, waited, completed))
        end
        if completed < end_i then
            timed_out = true
            emit(string.format("  ERROR: batch %d timed out (completed=%d/%d)",
                batch_idx + 1, completed, end_i))
            break
        end
        emit(string.format("  progress: %d/%d ok=%d fail=%d", completed, COUNT, success, fail_n))
    end

    local total_us = math.floor(utils.us_between(total_start, skynet.hpc()))

    -- 2. 统计
    table.sort(latencies)
    table.sort(connect_us)
    table.sort(login_us)
    table.sort(ping_us)
    local n = #latencies
    emit("\n" .. string.rep("=", 60))
    emit(string.format("  Total logins:     %d", COUNT))
    emit(string.format("  Success:          %d (%.2f%%)", success, success / COUNT * 100))
    emit(string.format("  Failed:           %d (connect_fail=%d)", fail_n, connect_fail))
    emit(string.format("  Agent ping ok:    %d/%d", ping_ok, math.min(PING_SAMPLE, success)))
    emit(string.format("  Total time:       %.1f ms", total_us / 1000))
    emit(string.format("  Throughput:       %.1f login/s", total_us > 0 and COUNT / (total_us / 1000000) or 0))
    emit(string.format("  Avg latency:      %.1f us", utils.average_us(latencies)))
    emit(string.format("  P50 latency:      %d us (%.2f ms)", utils.percentile(latencies, 0.50), utils.percentile(latencies, 0.50) / 1000))
    emit(string.format("  P90 latency:      %d us (%.2f ms)", utils.percentile(latencies, 0.90), utils.percentile(latencies, 0.90) / 1000))
    emit(string.format("  P99 latency:      %d us (%.2f ms)", utils.percentile(latencies, 0.99), utils.percentile(latencies, 0.99) / 1000))
    emit(string.format("  Max latency:      %d us", n > 0 and latencies[n] or 0))
    emit(string.format("  -- connect P50/P90: %d / %d us", utils.percentile(connect_us, 0.50), utils.percentile(connect_us, 0.90)))
    emit(string.format("  -- login   P50/P90: %d / %d us", utils.percentile(login_us, 0.50), utils.percentile(login_us, 0.90)))
    emit(string.format("  -- ping    P50/P90: %d / %d us", utils.percentile(ping_us, 0.50), utils.percentile(ping_us, 0.90)))
    emit(string.format("  -- ping r1/r2/r3 avg: %.0f / %.0f / %.0f us",
        (ping_rounds[1] or 0) / math.max(1, success),
        (ping_rounds[2] or 0) / math.max(1, success),
        (ping_rounds[3] or 0) / math.max(1, success)))
    if next(errors) then
        emit("  Error distribution:")
        for code, cnt in pairs(errors) do
            emit(string.format("    %s: %d", tostring(code), cnt))
        end
    end
    local ok_cnt, gate_online = pcall(skynet.call, gate, "lua", "online_count")
    emit(string.format("  Gate connections: %s", tostring(ok_cnt and gate_online)))
    emit(string.rep("=", 60))

    -- 3. 清理
    pcall(skynet.call, center, "lua", "logout_all")

    -- 4. 报告
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
    "p50_latency_us": %d,
    "p90_latency_us": %d,
    "p99_latency_us": %d,
    "max_latency_us": %d,
    "agent_ping_ok": %d,
    "errors": {%s}
}]],
        os.date("%Y-%m-%dT%H:%M:%S"),
        COUNT, success, fail_n, success / COUNT * 100,
        total_us / 1000,
        total_us > 0 and COUNT / (total_us / 1000000) or 0,
        utils.average_us(latencies),
        utils.percentile(latencies, 0.50),
        utils.percentile(latencies, 0.90),
        utils.percentile(latencies, 0.99),
        n > 0 and latencies[n] or 0,
        ping_ok,
        table.concat(err_parts, ",")
    )
    local f = io.open(REPORT_FILE, "w")
    if f then
        f:write(report)
        f:close()
        emit(string.format("  Report written to: %s", REPORT_FILE))
    end

    local all_pass = (fail_n == 0 and not timed_out and ping_ok == math.min(PING_SAMPLE, success))
    emit(all_pass and "  ALL TESTS PASSED" or "  TESTS FAILED")

    return {
        pass    = all_pass and 1 or 0,
        fail    = all_pass and 0 or 1,
        summary = table.concat(out, "\n"),
    }
end

local handlers = {}
function handlers.run(center, gate)
    return run(center, gate)
end

require "shared.service".start("stress_e2e", handlers)

return handlers
