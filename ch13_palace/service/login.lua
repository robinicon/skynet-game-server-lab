-- service/login.lua — test 渠道（sdkId=0）最小登录：账号 + session token
--
-- 密码规则与原工程一致：md5(客户端传来的 32 位 md5 串 .. salt)

local skynet = require "skynet"
local md5    = require "md5"
local schema = require "shared.schema"

local CMD = {}
local db
local sessions = {}
local accounts_created = 0

local function random_token()
    math.randomseed(math.floor(skynet.time() * 1000000) % 2147483647)
    return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

local function random_salt()
    return string.format("%08x", math.random(0, 0x7fffffff))
end

function CMD.init(db_addr)
    db = db_addr
    return true
end

function CMD.create_account(name, client_md5)
    if not name or not client_md5 then return schema.errors.BAD_ACCOUNT, 0 end
    local salt = random_salt()
    local hash = md5.sumhexa(client_md5 .. salt)
    local ok, res = skynet.call(db, "lua", "create_account", name, salt, hash)
    if not ok then return res, 0 end
    accounts_created = accounts_created + 1
    return schema.errors.OK, res
end

function CMD.auth(name, client_md5)
    local acc = skynet.call(db, "lua", "get_account", name)
    if not acc then return schema.errors.BAD_ACCOUNT, 0, "" end
    if md5.sumhexa(client_md5 .. acc.salt) ~= acc.hash then
        return schema.errors.BAD_PASSWORD, 0, ""
    end
    local token = random_token()
    sessions[token] = { uid = acc.uid, name = name, ts = skynet.time() }
    return schema.errors.OK, acc.uid, token
end

function CMD.login_by_token(token)
    local s = sessions[token]
    if not s then return schema.errors.BAD_ACCOUNT, 0, "" end
    return schema.errors.OK, s.uid, s.name
end

function CMD.stats()
    local n = 0
    for _ in pairs(sessions) do n = n + 1 end
    return { sessions = n, accounts_created = accounts_created }
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "login: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function() end)
