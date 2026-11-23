-- runtime.lua — ch8_components 运行时配置加载器

local M = {}

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

M.component_count = 3
M.split_threshold = 1000
M.test_target     = nil

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
    local t = os.getenv("CH8_TEST_TARGET")
    if t and t ~= "" then M.test_target = t end
end

parse_conf("conf/skynet.conf")
merge_env()

return M
