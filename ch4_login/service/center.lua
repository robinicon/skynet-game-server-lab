-- service/center.lua — 账号中心（uniqueservice）
-- 依赖：shared/
--
-- 职责：
--   1. 账号验证（内存字典，ch7_db 阶段替换为 DB）
--   2. Token 签发 / 校验 / 过期清理（分桶，O(1) 回收）
--   3. 在线状态与 Agent 登记
--   4. 运行指标统计（供 ch9_http /health 使用）
--
-- 并发策略：center 是单服务，lua 消息天然串行调度，无需额外 queue。
--
-- 状态表：
--   accounts[username] = { uid, password }
--   online[uid]        = { token, agent, login_time, expire_at }
--   token_index[token] = { uid, expire_at }
--   buckets[bkey]      = { [token] = true }     分桶，用于整桶过期回收

local skynet     = require "skynet"
local error_code = require "shared.error_code"
local token_mod  = require "shared.token"
local service    = require "shared.service"

-- ========== 内部状态 ==========
local accounts    = {}
local online      = {}
local token_index = {}
local buckets     = {}
local next_uid    = 1

local BUCKET = 300            -- 分桶粒度（秒）
local TTL    = token_mod.TTL

-- 日志降噪：登录成功默认不打日志（压测 1000 次 = 1000 条跨服务消息 + IO）
local VERBOSE = os.getenv("CH4_VERBOSE") == "1"
local counters = {
    login_ok        = 0,
    login_fail      = 0,
    login_by_token  = 0,
    logout          = 0,
    verify_ok       = 0,
    verify_fail     = 0,
    expired_cleaned = 0,
    start_time      = skynet.time(),
}

-- 用数组而非 hash 表：pairs 遍历顺序不确定，会导致 uid 分配不稳定
-- ⚠️ 以下是教学演示用的固定账号，仅供本地测试。生产环境必须从配置/账号服务加载，
--    绝不可把明文口令硬编码进代码库。
local init_accounts = {
    { name = "admin",   password = "admin123" },
    { name = "player1", password = "pass1"    },
    { name = "player2", password = "pass2"    },
}

-- ========== 工具 ==========
local function bkey_of(expire_at)
    return math.floor(expire_at / BUCKET)
end

local function bucket_add(token, expire_at)
    local bk = bkey_of(expire_at)
    local b = buckets[bk]
    if not b then
        b = {}
        buckets[bk] = b
    end
    b[token] = true
end

local function bucket_del(token, expire_at)
    local b = buckets[bkey_of(expire_at)]
    if b then
        b[token] = nil
    end
end

local function issue_token(uid)
    local token = token_mod.generate()
    local now = skynet.time()
    local expire_at = now + TTL
    online[uid] = {
        token      = token,
        agent      = nil,
        login_time = now,
        expire_at  = expire_at,
    }
    token_index[token] = { uid = uid, expire_at = expire_at }
    bucket_add(token, expire_at)
    return token, expire_at
end

local function drop_token(token)
    local rec = token_index[token]
    if not rec then
        return
    end
    token_index[token] = nil
    bucket_del(token, rec.expire_at)
end

-- ========== 初始化 ==========
local function init()
    local count = 0
    for _, acc in ipairs(init_accounts) do
        local uid = next_uid
        next_uid = uid + 1
        accounts[acc.name] = { uid = uid, password = acc.password }
        count = count + 1
    end
    skynet.error(string.format("[center] initialized with %d accounts", count))

    -- 过期清理：每 60 秒醒一次（skynet.sleep 单位 1/100 秒，60s = 6000）
    -- 旧实现写 600000 → 实际 6000 秒（100 分钟）才清理一次
    skynet.fork(function()
        while true do
            skynet.sleep(6000)
            local now = skynet.time()
            local cur = bkey_of(now)
            local cleaned = 0
            for bk, bucket in pairs(buckets) do
                if bk < cur then
                    for token in pairs(bucket) do
                        local rec = token_index[token]
                        if rec and rec.expire_at <= now then
                            local o = online[rec.uid]
                            if o and o.token == token and o.agent then
                                -- 仍在线且已绑定 agent：续期，不回收
                                local new_expire = now + TTL
                                rec.expire_at = new_expire
                                o.expire_at = new_expire
                                bucket[token] = nil
                                bucket_add(token, new_expire)
                            else
                                token_index[token] = nil
                                if o and o.token == token then
                                    online[rec.uid] = nil
                                end
                                cleaned = cleaned + 1
                            end
                        else
                            bucket[token] = nil
                        end
                    end
                    buckets[bk] = nil
                end
            end
            if cleaned > 0 then
                counters.expired_cleaned = counters.expired_cleaned + cleaned
                skynet.error(string.format("[center] token cleanup: %d expired", cleaned))
            end
        end
    end)
end

-- ========== 业务 ==========
local function do_login(username, password)
    local account = accounts[username]
    if not account then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_UNKNOWN_ACCOUNT, nil, nil, "unknown account"
    end
    if account.password ~= password then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_WRONG_PASSWORD, nil, nil, "wrong password"
    end

    local uid = account.uid
    if online[uid] then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_ALREADY_LOGGED_IN, nil, nil, "already online"
    end

    local token = issue_token(uid)
    counters.login_ok = counters.login_ok + 1
    if VERBOSE then
        skynet.error(string.format("[center] login ok: uid=%d username=%s", uid, username))
    end
    return error_code.OK, uid, token, nil
end

--- 用 token 直接登录（免密重连）；签发新 token 作废旧 token
local function do_login_by_token(token)
    if not token_mod.wellformed(token) then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_INVALID_TOKEN, nil, nil, "malformed token"
    end
    local rec = token_index[token]
    if not rec then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_INVALID_TOKEN, nil, nil, "unknown token"
    end
    if token_mod.expired(rec.expire_at) then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_TOKEN_EXPIRED, nil, nil, "token expired"
    end
    local uid = rec.uid
    if online[uid] then
        counters.login_fail = counters.login_fail + 1
        return error_code.ERR_ALREADY_LOGGED_IN, nil, nil, "already online"
    end

    drop_token(token)
    local new_token = issue_token(uid)
    counters.login_by_token = counters.login_by_token + 1
    return error_code.OK, uid, new_token, nil
end

local function do_logout(uid)
    local o = online[uid]
    if o then
        -- 只清在线状态，token 保留到过期：
        --   1. design.md 要求"下次登录直接用 token，无需再输密码"（免密重连）
        --   2. verify_token 依赖 online 表，登出后自然失效（T4d）
        --   3. token_index 由分桶定时器按 TTL 回收，不会无限增长
        online[uid] = nil
        counters.logout = counters.logout + 1
        if VERBOSE then
            skynet.error(string.format("[center] logout: uid=%d", uid))
        end
    end
    return true
end

local function do_verify_token(token)
    if not token_mod.wellformed(token) then
        counters.verify_fail = counters.verify_fail + 1
        return error_code.ERR_INVALID_TOKEN, nil
    end
    local rec = token_index[token]
    if not rec then
        counters.verify_fail = counters.verify_fail + 1
        return error_code.ERR_INVALID_TOKEN, nil
    end
    if token_mod.expired(rec.expire_at) then
        counters.verify_fail = counters.verify_fail + 1
        return error_code.ERR_TOKEN_EXPIRED, nil
    end
    local o = online[rec.uid]
    if not o or o.token ~= token then
        counters.verify_fail = counters.verify_fail + 1
        return error_code.ERR_NOT_ONLINE, nil
    end
    counters.verify_ok = counters.verify_ok + 1
    return error_code.OK, rec.uid
end

local function register_many(prefix, count, password)
    local created = 0
    for i = 1, count do
        local username = prefix .. i
        if not accounts[username] then
            accounts[username] = { uid = next_uid, password = password }
            next_uid = next_uid + 1
            created = created + 1
        end
    end
    return created
end

local function count_online()
    local n = 0
    for _ in pairs(online) do
        n = n + 1
    end
    return n
end

-- ========== 命令表 ==========
local handlers = {}

function handlers.login(username, password)
    local code, uid, token, reason = do_login(username, password)
    return { code, uid, token, reason }
end

function handlers.login_by_token(token)
    local code, uid, new_token, reason = do_login_by_token(token)
    return { code, uid, new_token, reason }
end

function handlers.logout(uid)
    do_logout(uid)
    return "ok"
end

--- 批量登出（压测收尾 / 运维）
function handlers.logout_all()
    local n = 0
    for uid in pairs(online) do
        online[uid] = nil
        n = n + 1
    end
    -- token 全部失效（桶留待定时器回收，这里直接清空索引）
    local tokens = 0
    for token in pairs(token_index) do
        token_index[token] = nil
        tokens = tokens + 1
    end
    buckets = {}
    counters.logout = counters.logout + n
    return n, tokens
end

--- Agent 就绪登记（旧版缺失此命令，导致 agent:start() 静默失败）
function handlers.register_agent(uid, agent)
    local o = online[uid]
    if not o then
        return error_code.ERR_NOT_ONLINE
    end
    o.agent = agent
    return error_code.OK
end

function handlers.verify_token(token)
    local code, uid = do_verify_token(token)
    return { code, uid }
end

function handlers.online_list()
    local list = {}
    for uid, info in pairs(online) do
        list[#list + 1] = {
            uid = uid,
            token = info.token,
            login_time = info.login_time,
            agent = info.agent,
        }
    end
    return error_code.OK, list
end

function handlers.online_count()
    return count_online()
end

function handlers.register_many(prefix, count, password)
    return register_many(prefix, count, password)
end

--- 运行指标（ch9_http /health 直接取用）
function handlers.stats()
    local elapsed = skynet.time() - counters.start_time
    return {
        login_ok        = counters.login_ok,
        login_fail      = counters.login_fail,
        login_by_token  = counters.login_by_token,
        logout          = counters.logout,
        verify_ok       = counters.verify_ok,
        verify_fail     = counters.verify_fail,
        expired_cleaned = counters.expired_cleaned,
        online          = count_online(),
        accounts        = (function() local n = 0 for _ in pairs(accounts) do n = n + 1 end return n end)(),
        tokens          = (function() local n = 0 for _ in pairs(token_index) do n = n + 1 end return n end)(),
        qps             = elapsed > 0 and (counters.login_ok / elapsed) or 0,
        uptime          = elapsed,
    }
end

function handlers.log(...)
    skynet.error(table.concat({ ... }, " "))
    return "ok"
end

service.start("center", handlers, { on_init = init })
