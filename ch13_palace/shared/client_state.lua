-- shared/client_state.lua — 阶段 4：新协议客户端状态机（参考实现）
--
-- 这是给客户端团队移植的样板：老工程协议没有版本号，客户端要自己按
-- base_rev 校验增量、按 mask/values 应用字段。服务端不信任客户端状态，
-- 客户端仅用它避免重复/乱序应用导致的显示错乱。
--
-- 数据流：u.snapshot → apply_snapshot；u.delta → apply_delta。
-- 字段一律以 fid（数字）为键，含义由 schema 配置赋予。

local M = {}

local Client = {}
Client.__index = Client

function M.new()
    return setmetatable({ fields = {}, rev = 0, applied = 0, rejected = 0 }, Client)
end

-- 展开快照：{ [partition] = { [fid]=value } } → 扁平 { [fid]=value }
function Client:apply_snapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.partitions) ~= "table" then
        return false, "bad snapshot"
    end
    self.fields = {}
    for _, part in pairs(snapshot.partitions) do
        for fid, value in pairs(part) do
            self.fields[tonumber(fid)] = value
        end
    end
    self.rev = tonumber(snapshot.rev) or 0
    return true
end

-- 应用增量：base_rev 必须等于本地 rev（严格）；重复/过期一律拒绝
function Client:apply_delta(delta)
    if type(delta) ~= "table" or type(delta.mask) ~= "table" then
        self.rejected = self.rejected + 1
        return false, "bad delta"
    end
    local base = tonumber(delta.base_rev) or -1
    if base ~= self.rev then
        self.rejected = self.rejected + 1
        return false, string.format("stale delta: base=%d local=%d", base, self.rev)
    end
    for _, fid in ipairs(delta.mask) do
        self.fields[tonumber(fid)] = delta.values[fid]
    end
    self.rev = tonumber(delta.rev) or self.rev
    self.applied = self.applied + 1
    return true
end

function Client:get(fid)
    return self.fields[tonumber(fid)]
end

function Client:count()
    local n = 0
    for _ in pairs(self.fields) do n = n + 1 end
    return n
end

return M
