-- service/agent.lua — 模拟玩家 Agent（存盘的发起方）
--
-- 职责：
--   1. 持有角色内存数据
--   2. 常规存盘用 skynet.send（异步，不阻塞业务）
--   3. 退出前用 skynet.call（同步，确保落盘后才 skynet.exit）
--
-- design.md 关注的正是第 3 点："防止一半 SQL 执行后 Agent 已退出"。

local skynet = require "skynet"
local service = require "shared.service"

local uid    = nil
local db     = nil
local data   = nil
local saving = 0        -- 进行中的异步存盘数（退出前需等待归零）

local handlers = {}

function handlers.init(u, db_addr)
    uid = u
    db  = db_addr
    data = { hp = 100, gold = 0 }
    return true
end

function handlers.load()
    local row = skynet.call(db, "lua", "load", uid)
    if row then
        data.hp   = row.hp or data.hp
        data.gold = row.gold or data.gold
    end
    return data
end

--- 修改内存数据
function handlers.modify(dhp, dgold)
    data.hp   = (data.hp or 0) + (tonumber(dhp) or 0)
    data.gold = (data.gold or 0) + (tonumber(dgold) or 0)
    return data
end

--- 异步存盘（常规路径）：不等待结果
function handlers.save_async()
    saving = saving + 1
    skynet.fork(function()
        pcall(skynet.call, db, "lua", "save_async", uid, { hp = data.hp, gold = data.gold })
        saving = saving - 1
    end)
    return true
end

--- 同步存盘（关键节点）：阻塞到落盘完成
function handlers.save_sync()
    local ok = skynet.call(db, "lua", "save_sync", uid, { hp = data.hp, gold = data.gold })
    return ok
end

--- 退出：先等异步存盘归零，再同步存盘一次，最后才 exit
-- 顺序不能反：先 exit 再存盘 → 数据丢失；只等异步不补一次同步 → 可能漏掉最后的状态
function handlers.exit()
    local waited = 0
    while saving > 0 and waited < 500 do
        skynet.sleep(1)
        waited = waited + 1
    end
    local ok = handlers.save_sync()
    skynet.error(string.format("[agent] exit: uid=%s saved=%s pending=%d",
        tostring(uid), tostring(ok), saving))
    return ok
end

function handlers.get()
    return { uid = uid, hp = data.hp, gold = data.gold, saving = saving }
end

service.start("agent", handlers)
