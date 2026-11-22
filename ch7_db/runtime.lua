-- runtime.lua — ch7_db 运行时配置加载器

local M = {}

M.root        = "./"
M.cpath       = "../skynet/cservice/?.so"
M.lua_cpath   = "../skynet/luaclib/?.so"
M.luaservice  = "./service/?.lua;./test/?.lua;./shared/?.lua;./?.lua;../skynet/service/?.lua"
M.lua_path    = "./?.lua;./shared/?.lua;./service/?.lua;./test/?.lua;../skynet/lualib/?.lua;../skynet/lualib/?/init.lua"
M.lualoader   = "../skynet/lualib/loader.lua"
M.thread      = 8
M.harbor      = 0
M.logpath     = "."
M.logger      = nil

M.db_driver     = "memory"
M.db_latency    = 1
M.db_slow_uid   = 100
M.pool_min      = 1
M.pool_max      = 8
M.pool_hard_max = 32
M.test_target   = nil

local function parse_conf(path)
    local f = io.open(path, "r")
    if not f then return end
    for l in f:lines() do
        local cleaned = l:gsub("%s*#.*$", ""):gsub("%s+$", "")
        if cleaned ~= "" then
            local key, val = cleaned:match("^([%w_]+)%s*=%s*(.+)$")
            if key and val then
                val = val:gsub("%s+$", ""):gsub("^['\"]", ""):gsub("['\"]$", "")
                M[key] = val
            end
        end
    end
    f:close()
end

local function merge_env()
    local t = os.getenv("CH7_TEST_TARGET")
    if t and t ~= "" then M.test_target = t end

    -- CH7_DB_DRIVER 覆盖 conf 的 db_driver（memory | mysql）。
    -- 之前仅靠 service/db.lua 的 os.getenv 兜底，但 main.lua 总会传入 conf.db_driver，
    -- 使那个兜底永不触发，导致该环境变量形同虚设。这里在配置源头合并，确保真正生效。
    local k = os.getenv("CH7_DB_DRIVER")
    if k and k ~= "" then M.db_driver = k end
end

parse_conf("conf/skynet.conf")
merge_env()

return M
