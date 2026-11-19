-- runtime.lua — 运行时配置加载器（位于根目录）
--
-- 读取 conf/skynet.conf 中的配置，并通过环境变量注入测试目标。
-- 注意1：必须放在根目录并用 require "runtime" 引用，
--   package.path 中最前面是 ./?.lua（根目录模式），conf/ 下的模块会解析到错误路径。
-- 注意2：skynet 不解析 --key=value 命令行参数（只读 argv[1] 配置文件），
--   所以测试目标只能通过环境变量传入（见 Makefile _test 目标）。
--
-- 用法：
--   local conf = require "runtime"
--   print(conf.gate_port)     -- 8888
--   print(conf.test_target)   -- 由环境变量 CH4_TEST_TARGET 传入

local M = {}

-- 默认值（由 skynet.conf 实际覆盖）
M.root        = "./"
M.cpath       = "../skynet/cservice/?.so"
M.lua_cpath   = "../skynet/luaclib/?.so"
M.luaservice  = "./service/?.lua;./gateway/?.lua;./test/?.lua;./shared/?.lua;./proto/?.lua;./conf/?.lua;../skynet/service/?.lua"
M.lua_path    = "./?.lua;./shared/?.lua;./proto/?.lua;./service/?.lua;./test/?.lua;./gateway/?.lua;./conf/?.lua;../skynet/lualib/?.lua;../skynet/lualib/?/init.lua"
M.lualoader   = "../skynet/lualib/loader.lua"
M.thread      = 8
M.harbor      = 0
M.logpath     = "."
M.logger      = nil

-- 业务配置
M.gate_address = "0.0.0.0"
M.gate_port    = 8888     -- Gate 监听端口
M.maxclient    = 2048     -- 1000 人压测需大于默认 1024
M.test_target  = nil      -- 由环境变量 CH4_TEST_TARGET 覆盖

--- 解析 skynet.conf 文件
local function parse_conf(path)
    local f = io.open(path, "r")
    if not f then
        return
    end
    for l in f:lines() do
        local cleaned = l:gsub("%s*#.*$", "")  -- 去掉注释
        cleaned = cleaned:gsub("%s+$", "")      -- 去掉尾部空格
        if cleaned ~= "" then
            local key, val = cleaned:match("^([%w_]+)%s*=%s*(.+)$")
            if key and val then
                val = val:gsub("%s+$", "")
                val = val:gsub("^['\"]", ""):gsub("['\"]$", "")
                M[key] = val
            end
        end
    end
    f:close()
end

--- 合并环境变量（skynet 忽略 --key=value，测试目标只能走环境变量）
local function merge_env()
    local target = os.getenv("CH4_TEST_TARGET")
    if target and target ~= "" then
        M.test_target = target
    end
end

-- 初始化：加载配置文件 + 合并环境变量
parse_conf("conf/skynet.conf")
merge_env()

return M
