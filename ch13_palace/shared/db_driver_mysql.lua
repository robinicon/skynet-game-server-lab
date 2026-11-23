-- shared/db_driver_mysql.lua — MySQL 驱动（阶段 2）
--
-- 实现与 db_driver_memory 完全相同的方法契约；上层（login/agent/gated）无感知。
-- 表结构见 conf/ddl.sql：6 张表承载抽象数据。
--   account            : uid/name/salt/pwd_hash
--   entity             : uid/etype/owner/account/rev/updated_at
--   entity_partition   : uid/partition/rev/payload(JSON fid→value)/crc  ← 只写脏分区
--   entity_field       : uid/fid/value  ← 只写 persist=index 字段
--   event_log          : 变更审计（save 时记一条）
--   leaderboard_projection : 派生投影（本阶段建表，不写）
--
-- 同步调用说明：db 服务是串行单点，所有进程内请求都收敛到它；同步 MySQL 调用
-- 不会引入并发冲突，与抽象存储「单线程收敛」契约一致。生产可换连接池/异步驱动，
-- 上层契约不变。

local skynet = require "skynet"
local schema = require "shared.schema"
local json   = require "shared.json"
local mysql  = require "mysql"

local M = {}
local D = {}
D.__index = D

local function new_partitions()
    local ps = {}
    for name in pairs(schema.fields.partitions) do
        ps[name] = { rev = 0, data = {} }
    end
    return ps
end

local function q(s)
    if s == nil then return "NULL" end
    return "'" .. tostring(s):gsub("\\", "\\\\"):gsub("'", "''") .. "'"
end

local function num(v)
    if type(v) == "number" then return v end
    return tonumber(v) or 0
end

local function crc32ish(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

function D:log_change(uid, written)
    local pids = table.concat(written, ",")
    self.conn:exec(string.format(
        "INSERT INTO event_log(uid,aid,ts,actor) VALUES(%d,%d,%d,%s)",
        uid, 0, os.time(), q("save:" .. pids)))
end

function D:init(conf)
    local host     = conf.db_host or "127.0.0.1"
    local port     = tonumber(conf.db_port) or 3306
    local user     = conf.db_user or "dev"
    local password = conf.db_password or "dev123"
    local database = conf.db_name or "ch13_palace"

    local ok, err = pcall(function()
        self.conn = mysql.connect(host, port, user, password, database)
    end)
    if not ok then
        return false, "mysql connect: " .. tostring(err)
    end
    skynet.error(string.format("[db:mysql] connected %s:%d/%s as %s",
        host, port, database, user))

    -- 幂等建表：读 conf/ddl.sql，按分号切分逐条执行
    local f = io.open("conf/ddl.sql", "r")
    if not f then return false, "cannot open conf/ddl.sql" end
    local ddl = f:read("*a")
    f:close()
    for stmt in ddl:gmatch("[^;]+") do
        local clean = stmt:gsub("%-%-[^\n]*", ""):gsub("%s+$", ""):gsub("^%s+", "")
        if clean ~= "" then self.conn:exec(clean) end
    end

    -- 从 MySQL 重建内存热缓存（契约不变：load() 仍返回带 __rev 的 state）
    self.accounts = {}
    self.entities = {}
    for _, r in ipairs(self.conn:query("SELECT uid,name,salt,pwd_hash FROM account")) do
        self.accounts[r.name] = {
            uid = num(r.uid), salt = r.salt, hash = r.pwd_hash,
        }
    end
    for _, r in ipairs(self.conn:query(
            "SELECT uid,etype,owner,account,rev FROM entity")) do
        local uid = num(r.uid)
        self.entities[uid] = {
            uid = uid, etype = r.etype, owner = num(r.owner),
            rev = num(r.rev), partitions = new_partitions(), index = {},
        }
        if uid > self.next_uid then self.next_uid = uid end
    end
    for _, r in ipairs(self.conn:query(
            "SELECT uid,`partition` AS part,rev,payload FROM entity_partition")) do
        local e = self.entities[num(r.uid)]
        if e then
            local data = json.decode(r.payload) or {}
            e.partitions[r.part] = { rev = num(r.rev), data = data }
        end
    end
    for _, r in ipairs(self.conn:query("SELECT uid,fid,value FROM entity_field")) do
        local e = self.entities[num(r.uid)]
        if e then e.index[num(r.fid)] = json.decode(r.value) end
    end
    skynet.error(string.format("[db:mysql] loaded %d accounts, %d entities",
        self:stats().accounts, self:stats().entities))
    return true
end

function D:create_account(name, salt, hash, uid)
    if self.accounts[name] then return false, schema.errors.EXISTS end
    if not uid then uid = self.next_uid self.next_uid = self.next_uid + 1 end
    self.conn:exec(string.format(
        "INSERT INTO account(uid,name,salt,pwd_hash,sdk_id,status) VALUES(%d,%s,%s,%s,0,0)",
        uid, q(name), q(salt), q(hash)))
    self.accounts[name] = { uid = uid, salt = salt, hash = hash }
    return true, uid
end

function D:get_account(name)
    local a = self.accounts[name]
    if not a then return nil end
    return { salt = a.salt, hash = a.hash, uid = a.uid }
end

function D:create_entity(etype, owner, account_name, explicit_uid)
    local uid = explicit_uid
    if uid then
        if uid >= self.next_uid then self.next_uid = uid + 1 end
    else
        self.next_uid = self.next_uid + 1
        uid = self.next_uid
    end
    self.conn:exec(string.format(
        "INSERT INTO entity(uid,etype,owner,account,rev,updated_at) VALUES(%d,%s,%d,%s,1,%d)",
        uid, q(etype or "avatar"), owner or 0, q(account_name or ""), os.time()))

    self.entities[uid] = {
        uid = uid, etype = etype or "avatar", owner = owner or 0,
        rev = 1, partitions = new_partitions(), index = {},
    }
    local p = self.entities[uid].partitions.base.data
    schema.set(p, "uid", uid)
    schema.set(p, "account", account_name or "")
    schema.set(p, "level", 1)
    schema.set(p, "gold", 0)
    self.entities[uid].index[schema.fid("uid")] = uid
    self.entities[uid].index[schema.fid("account")] = account_name or ""
    for name in pairs(schema.fields.partitions) do self:mark_dirty(uid, name) end

    -- 实体创建即落库所有分区（首次写入）
    self:save(uid)
    return uid
end

function D:mark_dirty(uid, pid)
    self.dirty[uid] = self.dirty[uid] or {}
    self.dirty[uid][pid] = true
end

function D:entity_snapshot(uid)
    local e = self.entities[uid]
    if not e then return nil end
    local state = { __rev = e.rev }
    for _, p in pairs(e.partitions) do
        for fid, v in pairs(p.data) do state[fid] = v end
    end
    return state
end

function D:find_entity_by_account(name)
    for uid, e in pairs(self.entities) do
        local state = self:entity_snapshot(uid)
        if state and state[schema.fid("account")] == name then return uid end
    end
    return nil
end

function D:load(uid)
    local state = self:entity_snapshot(uid)
    if not state then return nil, "entity not found" end
    return state
end

function D:set_fields(uid, changes)
    local e = self.entities[uid]
    if not e then return false, "entity not found" end
    if type(changes) ~= "table" then return false, "changes must be table" end
    local written = {}
    for name, value in pairs(changes) do
        local f, err = schema.field(name)
        if not f then return false, err end
        local p = e.partitions[f.partition]
        if not p then return false, "unknown partition " .. tostring(f.partition) end
        local ok, serr = schema.set(p.data, name, value)
        if not ok then return false, serr end
        if f.persist == "index" then e.index[f.fid] = value end
        if not written[f.partition] then
            written[f.partition] = true
            self:mark_dirty(uid, f.partition)
        end
    end
    if next(changes) then e.rev = e.rev + 1 end
    local list = {}
    for pid in pairs(written) do list[#list + 1] = pid end
    table.sort(list)
    self.last_written = list
    return true, { rev = e.rev, written = list }
end

function D:save(uid)
    local e = self.entities[uid]
    if not e then return false, "entity not found" end
    local list = {}
    for pid in pairs(self.dirty[uid] or {}) do list[#list + 1] = pid end
    table.sort(list)
    if #list == 0 then
        self.last_written = list
        return true, { rev = e.rev, written = list }
    end

    -- 单事务：脏分区 upsert + rev 更新 + 索引字段 upsert
    local ok, err = pcall(function()
        self.conn:exec("START TRANSACTION")
        for _, pid in ipairs(list) do
            local p = e.partitions[pid]
            p.rev = e.rev
            local payload = json.encode(p.data)
            self.conn:exec(string.format(
                [[INSERT INTO entity_partition(uid,`partition`,rev,payload,crc)
                   VALUES(%d,%s,%d,%s,%d)
                   ON DUPLICATE KEY UPDATE rev=VALUES(rev),payload=VALUES(payload),crc=VALUES(crc)]],
                uid, q(pid), p.rev, q(payload), crc32ish(payload)))
        end
        self.conn:exec(string.format(
            "UPDATE entity SET rev=%d,updated_at=%d WHERE uid=%d", e.rev, os.time(), uid))
        for fid, value in pairs(e.index) do
            self.conn:exec(string.format(
                [[INSERT INTO entity_field(uid,fid,value) VALUES(%d,%d,%s)
                   ON DUPLICATE KEY UPDATE value=VALUES(value)]],
                uid, fid, q(json.encode(value))))
        end
        self.conn:exec("COMMIT")
    end)
    if not ok then
        pcall(function() self.conn:exec("ROLLBACK") end)
        return false, "mysql save failed: " .. tostring(err)
    end

    self.dirty[uid] = {}
    self.last_written = list
    self:log_change(uid, list)
    return true, { rev = e.rev, written = list }
end

function D:flush()
    for uid in pairs(self.entities) do
        local ok, err = self:save(uid)
        if not ok then return false, err end
    end
    return true
end

function D:reset()
    for _, sql in ipairs({
        "DELETE FROM entity_partition", "DELETE FROM entity_field",
        "DELETE FROM event_log", "DELETE FROM entity", "DELETE FROM account",
    }) do self.conn:exec(sql) end
    self.accounts = {}
    self.entities = {}
    self.dirty = {}
    self.next_uid = 1000
    self.last_written = {}
    return true
end

function D:stats()
    local ec, ac = 0, 0
    for _ in pairs(self.entities) do ec = ec + 1 end
    for _ in pairs(self.accounts) do ac = ac + 1 end
    return { entities = ec, accounts = ac, last_written = self.last_written }
end

function D:driver_name() return "mysql" end

function M.new()
    return setmetatable({
        accounts = {}, entities = {}, dirty = {}, next_uid = 1000,
        last_written = {}, conn = nil,
    }, D)
end

return M
