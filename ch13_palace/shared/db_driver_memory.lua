-- shared/db_driver_memory.lua — 内存驱动（阶段 0 基线，作对照）
--
-- 与 MySQL 驱动实现完全相同的方法契约：
--   init / create_account / get_account / create_entity / find_entity_by_account
--   load / set_fields / save / flush / stats / reset / driver_name
-- 状态常驻内存，flush 写 JSON 快照。

local skynet = require "skynet"
local schema = require "shared.schema"
local json   = require "shared.json"

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

function D:init(conf)
    self.snapshot_path = conf.snapshot_path or self.snapshot_path
    local f = io.open(self.snapshot_path, "r")
    if f then
        local text = f:read("*a")
        f:close()
        local doc, err = json.decode(text)
        if not doc then return false, "bad snapshot: " .. tostring(err) end
        self.accounts = doc.accounts or {}
        self.entities = doc.entities or {}
        for _, e in pairs(self.entities) do
            e.partitions = e.partitions or new_partitions()
            e.index = e.index or {}
            e.rev = e.rev or 0
            for _, p in pairs(e.partitions) do p.rev = p.rev or 0 end
            if e.uid and e.uid > self.next_uid then self.next_uid = e.uid end
        end
    else
        skynet.error("[db:memory] no snapshot, starting empty")
    end
    return true
end

function D:create_account(name, salt, hash, uid)
    if self.accounts[name] then return false, schema.errors.EXISTS end
    if not uid then uid = self.next_uid self.next_uid = self.next_uid + 1 end
    self.accounts[name] = { salt = salt, hash = hash, uid = uid }
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
    return uid
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
    for pid in pairs(self.dirty[uid] or {}) do
        e.partitions[pid].rev = e.rev
        list[#list + 1] = pid
    end
    table.sort(list)
    self.dirty[uid] = {}
    self.last_written = list
    return true, { rev = e.rev, written = list }
end

function D:flush()
    local dir = self.snapshot_path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. dir) end
    local f = io.open(self.snapshot_path, "w")
    if not f then return false, "cannot open " .. self.snapshot_path end
    f:write(json.encode({ accounts = self.accounts, entities = self.entities }))
    f:close()
    return true
end

function D:reset()
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

function D:driver_name() return "memory" end

function M.new()
    return setmetatable({
        accounts = {}, entities = {}, dirty = {}, next_uid = 1000,
        last_written = {}, snapshot_path = "data/snapshot.json",
    }, D)
end

return M
