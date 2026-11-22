-- shared/db_driver.lua — 数据库驱动抽象
--
-- 两种实现：
--   memory —— 内存表，用于无 MySQL 环境下的回归测试（默认）
--   mysql  —— 封装 skynet.db.mysql，用于真实环境
--
-- ⚠️ 最关键的一点：**memory 驱动必须注入 yield**
--
--   如果 mock 驱动是纯同步的（不 yield），任何"并发存盘"测试都不会暴露问题——
--   因为单线程 Lua 的读-改-写在没有 yield 点时天然原子，丢失更新根本不会发生。
--   真实 MySQL 查询一定会 yield（网络往返），所以 mock 必须模拟这个 yield，
--   否则测试是**假绿**的：看起来通过了，实际什么都没验证。
--
--   本驱动用 skynet.sleep(latency) 模拟网络往返，latency 可配置（tick 数，1 tick = 10ms）。
--   测试里用 latency=1 制造真实的交错窗口。

local skynet = require "skynet"

local M = {}

-- ============================================================
-- memory 驱动
-- ============================================================
local Memory = {}
Memory.__index = Memory

--- @param opts.latency   number 每次操作的模拟往返 tick 数（0 = 不 yield）
--- @param opts.slow_uid  number 指定 uid 的操作额外慢 N 倍（隔离性测试用）
function M.new_memory(opts)
    opts = opts or {}
    return setmetatable({
        kind     = "memory",
        latency  = opts.latency or 0,
        slow_uid = opts.slow_uid,
        slow_mul = opts.slow_mul or 10,
        rows     = {},          -- uid → { uid, hp, gold, version, updated_at }
        stats    = { load = 0, save = 0, yield = 0 },
    }, Memory)
end

--- 模拟一次网络往返（关键：制造 yield 点）
function Memory:_rtt(uid)
    local t = self.latency
    if uid and self.slow_uid and uid == self.slow_uid then
        t = t * self.slow_mul
    end
    if t > 0 then
        self.stats.yield = self.stats.yield + 1
        skynet.sleep(t)      -- skynet.sleep 单位 = 1/100 秒
    end
end

function Memory:load_role(uid)
    self:_rtt(uid)
    self.stats.load = self.stats.load + 1
    return self.rows[uid]
end

function Memory:save_role(uid, data)
    self:_rtt(uid)
    self.stats.save = self.stats.save + 1
    local row = self.rows[uid]
    if not row then
        row = { uid = uid, version = 0 }
        self.rows[uid] = row
    end
    for k, v in pairs(data) do
        if k ~= "uid" then row[k] = v end
    end
    row.version = (row.version or 0) + 1
    row.updated_at = skynet.time()
    return true
end

function Memory:delete_role(uid)
    self:_rtt(uid)
    self.rows[uid] = nil
    return true
end

function Memory:count()
    local n = 0
    for _ in pairs(self.rows) do n = n + 1 end
    return n
end

-- ============================================================
-- mysql 驱动（真实环境）
-- ============================================================
local Mysql = {}
Mysql.__index = Mysql

--- @param opts table { host, port, user, password, database, ... }
function M.new_mysql(opts)
    local ok, mysql = pcall(require, "skynet.db.mysql")
    if not ok then
        return nil, "skynet.db.mysql not available: " .. tostring(mysql)
    end
    local db = mysql.connect(opts)
    if not db then
        return nil, "mysql.connect failed"
    end
    return setmetatable({
        kind  = "mysql",
        db    = db,
        opts  = opts,
        stats = { load = 0, save = 0, yield = 0 },
    }, Mysql)
end

function Mysql:_esc(v)
    local s = tostring(v)
    s = s:gsub("\\", "\\\\"):gsub("'", "\\'")
    return "'" .. s .. "'"
end

function Mysql:load_role(uid)
    self.stats.load = self.stats.load + 1
    self.stats.yield = self.stats.yield + 1
    local res = self.db:query(string.format(
        "SELECT uid, hp, gold, version FROM roles WHERE uid = %d LIMIT 1",
        tonumber(uid) or 0))
    if not res or type(res) ~= "table" or #res == 0 then
        return nil
    end
    local row = res[1]
    -- mysql 驱动把整数列返回为字符串，统一转成 number，
    -- 否则 hp == N（number）这类断言会因类型不同永远为 false。
    row.uid     = tonumber(row.uid)
    row.hp      = tonumber(row.hp) or 0
    row.gold    = tonumber(row.gold) or 0
    row.version = tonumber(row.version) or 0
    return row
end

function Mysql:save_role(uid, data)
    self.stats.save = self.stats.save + 1
    self.stats.yield = self.stats.yield + 1
    -- 部分更新语义：只写 data 里出现的字段，其余列保持原值，
    -- 与 memory 驱动逐字段合并的行为一致（D3.2 覆盖）。
    -- 用 COALESCE(新值, 旧列值)：新值为 nil 时 UPDATE 该列到自身，等于不动。
    local hp   = tonumber(data.hp)
    local gold = tonumber(data.gold)
    local sql = string.format(
        "INSERT INTO roles (uid, hp, gold, version) VALUES (%d, %s, %s, 1) " ..
        "ON DUPLICATE KEY UPDATE " ..
        "hp = COALESCE(%s, hp), gold = COALESCE(%s, gold), version = version + 1",
        uid,
        hp and tostring(hp) or "0",
        gold and tostring(gold) or "0",
        hp and tostring(hp) or "NULL",
        gold and tostring(gold) or "NULL")
    local res = self.db:query(sql)
    return res ~= false and res ~= nil
end

function Mysql:delete_role(uid)
    self.db:query(string.format("DELETE FROM roles WHERE uid = %d", uid))
    return true
end

--- 测试用清库：memory 驱动直接清表，mysql 驱动需下发 DELETE。
-- 与 memory 保持同一接口，供 service/db.lua 的 reset handler 调用。
function Mysql:reset()
    self.db:query("DELETE FROM roles")
    self.stats = { load = 0, save = 0, yield = 0 }
    return true
end

-- ============================================================
-- 连接句柄：连接池的 factory 调用它
--   memory 模式：所有连接共享同一张内存表（同一个"数据库"）
--   mysql 模式：每个连接是一条独立的 TCP 连接
-- ============================================================
function Memory:new_conn()
    return self
end

function Mysql:new_conn()
    local conn, err = M.new_mysql(self.opts)
    if not conn then
        return nil, err
    end
    return conn
end

function Mysql:close()
    if self.db and self.db.disconnect then
        pcall(self.db.disconnect, self.db)
    end
end

-- ============================================================
-- 工厂：由环境变量 CH7_DB_DRIVER 选择
-- ============================================================
function M.create(opts)
    opts = opts or {}
    local kind = opts.kind or os.getenv("CH7_DB_DRIVER") or "memory"
    if kind == "mysql" then
        return M.new_mysql(opts)
    end
    return M.new_memory(opts)
end

return M
