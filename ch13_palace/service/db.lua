-- service/db.lua — 抽象存储服务：驱动分发的薄层
--
-- 阶段 2：按 CH13_DB_DRIVER 选择后端（memory / mysql），上层契约完全不变。
--   memory : 内存表 + JSON 快照（阶段 0 基线，作对照）
--   mysql  : 6 张表 + 脏分区 upsert（阶段 2）
-- 两个驱动实现同一套方法，本文件只做转发，不含任何存储语义。

local skynet = require "skynet"

local CMD = {}
local driver

local function pick_driver()
    local name = os.getenv("CH13_DB_DRIVER") or "memory"
    if name == "mysql" then
        return require "shared.db_driver_mysql"
    elseif name == "memory" then
        return require "shared.db_driver_memory"
    end
    error("unknown CH13_DB_DRIVER: " .. tostring(name))
end

function CMD.init(conf)
    local mod = pick_driver()
    driver = mod.new()
    local ok, err = driver:init(conf or {})
    if not ok then
        skynet.error("[db] driver init failed: " .. tostring(err))
        return false, err
    end
    skynet.error("[db] driver = " .. driver:driver_name())
    return true
end

-- 统一转发：调用驱动的同名方法
local forwards = {
    "create_account", "get_account", "create_entity", "find_entity_by_account",
    "load", "set_fields", "save", "flush", "reset", "stats", "driver_name",
}
for _, name in ipairs(forwards) do
    CMD[name] = function(...)
        assert(driver, "db driver not initialized")
        return driver[name](driver, ...)
    end
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "db: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function() end)
