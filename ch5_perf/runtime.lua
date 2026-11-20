-- runtime.lua — 运行时配置加载器（位于根目录）
--
-- 与 ch4_login/runtime.lua 同构：
--   1. 必须放根目录，lua_path 最前面是 ./?.lua
--   2. skynet 不解析 --key=value，测试目标只能走环境变量

local M = {}

-- 默认值（由 conf/skynet.conf 实际覆盖）
M.root        = "./"
M.cpath       = "../skynet/cservice/?.so"
M.lua_cpath   = "../skynet/luaclib/?.so"
M.luaservice  = "./service/?.lua;./test/?.lua;./shared/?.lua;./?.lua;../skynet/service/?.lua"
M.lua_path    = "./?.lua;./shared/?.lua;./service/?.lua;./test/?.lua;../skynet/lualib/?.lua;../skynet/lualib/?/init.lua"
M.lualoader   = "../skynet/lualib/loader.lua"
M.thread      = 4
M.harbor      = 0
M.logpath     = "."
M.logger      = nil

-- 业务配置
M.bench_rounds = 100000
M.bench_hold   = 64
M.pool_max     = 1024
M.pool_prewarm = 32
M.test_target  = nil

--- 解析 skynet.conf
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

--- 合并环境变量
local function merge_env()
    local target = os.getenv("CH5_TEST_TARGET")
    if target and target ~= "" then
        M.test_target = target
    end
    local rounds = os.getenv("CH5_BENCH_ROUNDS")
    if rounds and rounds ~= "" then
        M.bench_rounds = tonumber(rounds) or M.bench_rounds
    end
end

parse_conf("conf/skynet.conf")
merge_env()

return M
