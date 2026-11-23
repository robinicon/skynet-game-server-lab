-- service/center_dist.lua — 分布式 Center（运行在 center1 / center2 节点）
--
-- 职责：
--   * 权威的 token 校验（数据落在 redis_auth 服务里，Center 自己不存状态）
--   * 在线状态登记（哪个 uid 在哪个节点上）
--   * 对外以 "@center" 这个名字被 cluster 寻址
--
-- 跨节点接口约定：所有命令返回 **至少 2 个值**，第一个是业务 ok。
-- 原因见 shared/dist_call.lua —— 只有这样才能把「网络层失败（单值 false）」
-- 和「业务返回 false」区分开。

local skynet  = require "skynet"
local cluster = require "skynet.cluster"

local node_name  = "?"
local redis_auth = nil

local online = {}          -- uid -> { node, at }
local n_online = 0         -- 自己维护计数：online 是 uid 为 key 的哈希表，#online 恒为 0

local n = { verify = 0, online = 0, ping = 0, hang = 0, echo = 0, issue = 0 }

local CMD = {}

function CMD.ping()
    n.ping = n.ping + 1
    return true, node_name
end

function CMD.issue(uid, ttl_cs)
    n.issue = n.issue + 1
    local ok, token, reason = skynet.call(redis_auth, "lua", "issue", uid, ttl_cs)
    if not ok then return false, tostring(reason) end
    return true, token
end

function CMD.issue_batch(uids, ttl_cs)
    n.issue = n.issue + #uids
    local ok, map, reason = skynet.call(redis_auth, "lua", "issue_batch", uids, ttl_cs)
    if not ok then return false, tostring(reason) end
    return true, map
end

-- 核心：跨节点 token 校验
function CMD.verify_token(uid, token)
    n.verify = n.verify + 1
    local ok, tuid, reason = skynet.call(redis_auth, "lua", "verify", token)
    if not ok then return false, tostring(reason) end
    if tuid ~= uid then return false, "uid_mismatch" end
    return true, "ok"
end

-- 高频路径：上报在线。调用方用 cluster.send 异步投递，这里不需要回包，
-- 但仍然返回 2 个值以遵守接口约定。
function CMD.report_online(uid, from)
    n.online = n.online + 1
    if online[uid] == nil then n_online = n_online + 1 end
    online[uid] = { node = from or "?", at = skynet.now() }
    return true, "ok"
end

function CMD.is_online(uid)
    local o = online[uid]
    if not o then return false, nil end
    return true, o.node
end

function CMD.echo(s)
    n.echo = n.echo + 1
    return true, s
end

-- 故障注入：永不返回，用来验证调用方的超时保护是否生效
function CMD.hang()
    n.hang = n.hang + 1
    skynet.error(string.format("[center_dist] %s hang: 永不返回", node_name))
    skynet.wait(coroutine.running())
end

function CMD.stats()
    local ra = nil
    if redis_auth then
        local ok, s = skynet.call(redis_auth, "lua", "stats")
        ra = ok and s or nil
    end
    return true, {
        node         = node_name,
        verify       = n.verify,
        online       = n.online,
        online_count = n_online,
        ping         = n.ping,
        hang         = n.hang,
        echo         = n.echo,
        issue        = n.issue,
        redis        = ra,
    }
end

function CMD.init(cfg)
    node_name     = cfg.node or "?"
    redis_auth    = skynet.newservice("redis_auth")

    -- 注册到 cluster 命名空间，远端用 "@center" 就能找到本服务。
    -- 注意：不能把 skynet.self() 这个 handle 直接传给别的节点用 ——
    -- handle 是进程内的，只有 "@name" / ".name" 这种名字寻址才是跨节点安全的。
    cluster.register("center", skynet.self())

    -- cluster.open 两种写法：
    --   cluster.open("center1")  —— 用节点名，端口从 cluster 配置里取
    --   cluster.open(2532)       —— 直接用端口号，监听 0.0.0.0
    -- 这里用端口号，避免依赖配置里本节点名一定存在。
    cluster.open(tonumber(cfg.port), 1024)

    skynet.error(string.format("[center_dist] node=%s ready, cluster port=%s",
        node_name, tostring(cfg.port)))
    return true, node_name
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
