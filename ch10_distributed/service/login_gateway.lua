-- service/login_gateway.lua — 登录接入（运行在 auth 节点）
--
-- 登录链路：
--   1) 先看本地 token 缓存（uid 维度，TTL 内命中直接放行）
--   2) miss → 跨节点 cluster.call(center_node, "@center", "verify_token", uid, token)
--          这一步是同步的：拿不到结果就不能放行，必须用 call
--   3) 校验通过 → 写本地缓存
--   4) 上报在线：cluster.send（异步，不等回包）—— 高频路径绝不阻塞登录
--
-- 选节点用一致性哈希（shared/balance.lua）：
--   同一个 uid 恒定落在同一个 center，center 侧才能做本地缓存和在线状态收敛。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"
local dist    = require "dist_call"
local balance = require "balance"

local ring
local center_nodes = {}

-- 本地校验缓存：uid -> { token, expire }。
-- 作用：重连/频繁登录时不再产生跨节点调用，把 O(N) 次 RPC 压成 O(1) 次。
-- 代价：token 被吊销后最长有 TTL 的窗口期仍然有效 —— 这是可用性换一致性的取舍，
--       对「踢下线」这类强一致需求必须走 center 的 del + 广播失效，不能只靠 TTL。
local cache = {}
local CACHE_TTL   = tonumber(os.getenv("CH10_CACHE_TTL")) or 3000   -- cs = 30s
local VNODES      = tonumber(os.getenv("CH10_VNODES"))     or 128

local st = { login = 0, cache_hit = 0, cross = 0, send = 0, fail = 0 }

local CMD = {}

function CMD.init(cfg)
    center_nodes = cfg.centers or {}
    ring = balance.new(center_nodes, VNODES)
    -- auth 节点自己也要开 cluster 端口，否则别的节点没法回调它
    cluster.open(tonumber(cfg.port), 1024)
    skynet.error(string.format("[login_gateway] centers=%s port=%s cache_ttl=%dcs vnodes=%d",
        table.concat(center_nodes, ","), tostring(cfg.port), CACHE_TTL, VNODES))
    return true, "ok"
end

function CMD.pick(uid)
    return true, ring:pick(uid)
end

-- 本地分布统计（不产生跨节点流量）
function CMD.dist(n, from)
    return true, ring:distribution(n or 1000, from or 1)
end

function CMD.login(uid, token)
    st.login = st.login + 1

    local c = cache[uid]
    local t = skynet.now()
    if c and c.token == token and c.expire > t then
        st.cache_hit = st.cache_hit + 1
        -- 命中缓存也要上报在线：这是高频路径，用 send 不等回包
        dist.send(ring:pick(uid), "@center", "report_online", uid, "auth")
        st.send = st.send + 1
        return true, "cache"
    end

    local node = ring:pick(uid)
    st.cross = st.cross + 1
    local ok, pack = dist.call(node, "@center", "verify_token", uid, token)
    if not ok then
        st.fail = st.fail + 1
        return false, "unreachable:" .. tostring(pack)
    end
    if not pack[1] then
        return false, tostring(pack[2])
    end

    cache[uid] = { token = token, expire = skynet.now() + CACHE_TTL }
    dist.send(node, "@center", "report_online", uid, "auth")
    st.send = st.send + 1
    return true, "center"
end

-- ---------------- 测试支撑接口 ----------------

function CMD.issue(uid, ttl)
    local node = ring:pick(uid)
    local ok, pack = dist.call(node, "@center", "issue", uid, ttl)
    if not ok then return false, tostring(pack) end
    return pack[1], pack[2]
end

-- 批量签发：按 center 分组，每组只发一次跨节点请求
function CMD.issue_batch(from_uid, count, ttl)
    local groups = {}
    for i = 0, (count or 1) - 1 do
        local uid  = from_uid + i
        local node = ring:pick(uid)
        local g = groups[node]
        if not g then g = {}; groups[node] = g end
        g[#g + 1] = uid
    end
    local tokens = {}
    for node, uids in pairs(groups) do
        local ok, pack = dist.call(node, "@center", "issue_batch", uids, ttl)
        if not ok then return false, tostring(pack) end
        if not pack[1] then return false, tostring(pack[2]) end
        for _, uid in ipairs(uids) do
            tokens[uid] = pack[2][uid]
        end
    end
    return true, tokens
end

-- 通用跨节点转发（测试用）
function CMD.center_call(node, cmd, ...)
    return dist.call(node, "@center", cmd, ...)
end

-- 带显式超时（测试用）
function CMD.call_ex(node, timeout_cs, cmd, ...)
    return dist.call_ex(node, "@center", timeout_cs, cmd, ...)
end

-- 启动探测：绕过熔断，不计入失败
function CMD.probe(node)
    local ok = dist.probe(node, "@center", "ping")
    return ok
end

function CMD.hang_call(node, timeout_cs)
    return dist.call_ex(node, "@center", timeout_cs, "hang")
end

-- 对照组：完全没有超时/熔断保护的裸调用（test_hang.lua 用）
function CMD.raw_call(node, addr, cmd, ...)
    return cluster.call(node, addr, cmd, ...)
end

-- 异步批量上报：测 cluster.send 的吞吐
function CMD.send_burst(node, n, from_uid)
    for i = 0, (n or 1) - 1 do
        dist.send(node, "@center", "report_online", (from_uid or 0) + i, "auth")
    end
    return true, n or 0
end

-- cluster 配置热更新（故障注入用）
function CMD.reload(cfg)
    cluster.reload(cfg)
    return true, "ok"
end

function CMD.breaker(node)
    return true, dist.breaker(node)
end

function CMD.run_gc()
    cache = {}
    return true, "ok"
end

function CMD.stats()
    return true, {
        login     = st.login,
        cache_hit = st.cache_hit,
        cross     = st.cross,
        send      = st.send,
        fail      = st.fail,
        cache_ttl = CACHE_TTL,
        vnodes    = VNODES,
        centers   = center_nodes,
        dist      = dist.stats(),
    }
end

function CMD.reset()
    dist.reset()
    return true, "ok"
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.retpack(false, "unknown_cmd:" .. tostring(cmd))
            return
        end
        skynet.retpack(f(...))
    end)
end)
