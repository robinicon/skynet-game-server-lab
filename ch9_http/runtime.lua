-- runtime.lua — ch9_http 运行时配置加载器

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

M.http_address = "127.0.0.1"
M.http_port    = 8899
M.http_backlog = 128
M.test_target  = nil

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
    local t = os.getenv("CH9_TEST_TARGET")
    if t and t ~= "" then M.test_target = t end

    -- CH9_HTTP_PORT 覆盖 conf 的 http_port；否则 Makefile 传的端口变量会被静默忽略
    local p = tonumber(os.getenv("CH9_HTTP_PORT"))
    if p then M.http_port = p end
end

parse_conf("conf/skynet.conf")
merge_env()

return M
