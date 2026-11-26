-- service/redis_auth.lua — token 存储与校验服务
--
-- 把「token 存在哪」这件事收敛到一个服务里，业务代码只认接口：
--   issue(uid, ttl)  -> token
--   verify(token)    -> ok, uid, reason
--   del(token)       -> ok, reason
--
-- 两种后端：
--   memory（默认） 进程内表 + 惰性过期。单机/测试用。
--   redis          走 skynet.db.redis，多节点共享，进程重启不丢。
--
-- 本环境（WSL）没有 redis-server，所以默认 memory；
-- redis 分支是完整实现，但需要 CH10_REDIS_BACKEND=redis 且真的有 Redis 才能跑。
-- 后端不可用时不会假装成功，而是统一返回 "backend_down"，由上层当故障处理。

local skynet = require "skynet"

local BACKEND = os.getenv("CH10_REDIS_BACKEND") or "memory"
local REDIS_HOST = os.getenv("CH10_REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = tonumber(os.getenv("CH10_REDIS_PORT")) or 6379
local REDIS_DB   = tonumber(os.getenv("CH10_REDIS_DB"))   or 0

local PREFIX = "ch10:tk:"

local tokens = {}            -- memory 后端: token -> { uid, expire }
local n_online_token = 0     -- 不能用 #tokens（token 是字符串 key，哈希部分不计入长度）
local conn            = nil  -- redis 后端连接
local backend_ok      = (BACKEND == "memory")

local stat = {
    issue = 0, verify = 0, hit = 0, miss = 0, del = 0,
    backend = BACKEND,
}

local function now()
    return skynet.now()      -- cs
end

-- ---------------- memory 后端 ----------------

local function mem_issue(uid, ttl_cs)
    stat.issue = stat.issue + 1
    local token = string.format("tk_%d_%d_%d", uid, now(), stat.issue)
    if tokens[token] == nil then n_online_token = n_online_token + 1 end
    tokens[token] = { uid = uid, expire = now() + ttl_cs }
    return true, token, "ok"
end

local function mem_verify(token)
    stat.verify = stat.verify + 1
    local r = tokens[token]
    if not r then
        stat.miss = stat.miss + 1
        return false, nil, "not_found"
    end
    if r.expire <= now() then
        tokens[token] = nil
        n_online_token = n_online_token - 1
        stat.miss = stat.miss + 1
        return false, r.uid, "expired"
    end
    stat.hit = stat.hit + 1
    return true, r.uid, "ok"
end

local function mem_del(token)
    stat.del = stat.del + 1
    if tokens[token] then
        tokens[token] = nil
        n_online_token = n_online_token - 1
        return true, "ok"
    end
    return false, "not_found"
end

-- ---------------- redis 后端 ----------------

local function redis_init()
    local ok, mod = pcall(require, "skynet.db.redis")
    if not ok then
        skynet.error("[redis_auth] require skynet.db.redis failed: " .. tostring(mod))
        return false
    end
    local ok2, db = pcall(mod.connect, {
        host = REDIS_HOST, port = REDIS_PORT, db = REDIS_DB,
    })
    if not ok2 or not db then
        skynet.error(string.format("[redis_auth] redis connect %s:%d failed: %s",
            REDIS_HOST, REDIS_PORT, tostring(db)))
        return false
    end
    conn = db
    return true
end

-- ttl 入参单位是 cs（10ms），SETEX 需要秒；不足 1 秒按 1 秒存（宁可长不可短）
local function cs_to_sec(ttl_cs)
    return math.max(1, math.ceil(ttl_cs / 100))
end

local function redis_issue(uid, ttl_cs)
    stat.issue = stat.issue + 1
    local token = string.format("tk_%d_%d_%d", uid, now(), stat.issue)
    local ok, err = pcall(conn.setex, conn, PREFIX .. token, cs_to_sec(ttl_cs), uid)
    if not ok then return false, nil, "backend_error:" .. tostring(err) end
    return true, token, "ok"
end

local function redis_verify(token)
    stat.verify = stat.verify + 1
    local ok, val = pcall(conn.get, conn, PREFIX .. token)
    if not ok then
        stat.miss = stat.miss + 1
        return false, nil, "backend_error"
    end
    if not val then
        stat.miss = stat.miss + 1
        return false, nil, "not_found"
    end
    stat.hit = stat.hit + 1
    return true, tonumber(val), "ok"
end

local function redis_del(token)
    stat.del = stat.del + 1
    local ok, n = pcall(conn.del, conn, PREFIX .. token)
    if not ok then return false, "backend_error" end
    return (tonumber(n) or 0) > 0, "ok"
end

-- ---------------- 分发 ----------------

local CMD = {}

function CMD.ping()
    return true, "pong"
end

function CMD.backend()
    return true, { backend = BACKEND, ok = backend_ok, conn = conn ~= nil }
end

function CMD.issue(uid, ttl_cs)
    if not backend_ok then return false, nil, "backend_down" end
    ttl_cs = tonumber(ttl_cs) or 5000
    if BACKEND == "redis" then return redis_issue(uid, ttl_cs) end
    return mem_issue(uid, ttl_cs)
end

-- 批量签发：一次调用签 N 个，避免 N 次跨进程往返
function CMD.issue_batch(uids, ttl_cs)
    if not backend_ok then return false, nil, "backend_down" end
    ttl_cs = tonumber(ttl_cs) or 5000
    local map = {}
    for _, uid in ipairs(uids) do
        local ok, token, reason
        if BACKEND == "redis" then
            ok, token, reason = redis_issue(uid, ttl_cs)
        else
            ok, token, reason = mem_issue(uid, ttl_cs)
        end
        if not ok then return false, nil, tostring(reason) end
        map[uid] = token
    end
    return true, map, "ok"
end

function CMD.verify(token)
    if not backend_ok then return false, nil, "backend_down" end
    if BACKEND == "redis" then return redis_verify(token) end
    return mem_verify(token)
end

function CMD.del(token)
    if not backend_ok then return false, "backend_down" end
    if BACKEND == "redis" then return redis_del(token) end
    return mem_del(token)
end

function CMD.stats()
    return true, {
        backend = BACKEND,
        ok      = backend_ok,
        issue   = stat.issue,
        verify  = stat.verify,
        hit     = stat.hit,
        miss    = stat.miss,
        del     = stat.del,
        -- 记住：token 是字符串 key，#tokens 永远是 0，必须自己维护计数器
        live    = n_online_token,
    }
end

skynet.start(function()
    if BACKEND == "redis" then
        backend_ok = redis_init()
        if not backend_ok then
            skynet.error("[redis_auth] 后端 redis 不可用，所有 token 操作将返回 backend_down")
        end
    end
    skynet.error(string.format("[redis_auth] backend=%s ok=%s", BACKEND, tostring(backend_ok)))

    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.retpack(false, "unknown_cmd:" .. tostring(cmd))
            return
        end
        skynet.retpack(f(...))
    end)
end)
