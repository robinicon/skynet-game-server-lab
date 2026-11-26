-- runtime.lua — ch10_distributed 运行时配置加载器
--
-- 三个节点共用一份代码，靠 skynet 启动时加载的那份 .conf 区分角色。
-- 关键：业务配置（node_name / cluster_port / center_nodes / test_target / cluster）
-- 都写在各节点的 .conf 里，由 skynet 内核解析，用 skynet.getenv 读取即可——
-- 它天然知道「当前进程到底加载了哪个 .conf」，不需要再靠 CH10_CONF 这种
-- 易漏传的环境变量去猜。
--
-- CH10_* 进程环境变量只用于单测调参覆盖（超时、熔断阈值、哈希虚拟节点数、
-- Redis 后端切换、临时指定 centers 等），优先级高于 .conf。

local skynet = require "skynet"

local M = {}

-- ---- 业务配置：来自 skynet 启动时解析的 .conf ----
M.cluster      = skynet.getenv("cluster")      or "./conf/clustername.lua"
M.node_name    = skynet.getenv("node_name")    or "auth"
M.cluster_port = tonumber(skynet.getenv("cluster_port")) or 2531
M.center_nodes = skynet.getenv("center_nodes") or ""
local tt       = skynet.getenv("test_target")
M.test_target  = (tt and tt ~= "") and tt or nil

-- ---- 路径类配置：skynet 内核已用 .conf 里的同名项初始化，这里只是给 Lua 侧留底 ----
M.root         = skynet.getenv("root")         or "./"
M.cpath        = "../skynet/cservice/?.so"
M.lua_cpath    = "../skynet/luaclib/?.so"
M.luaservice   = "./service/?.lua;./test/?.lua;./shared/?.lua;./?.lua;../skynet/service/?.lua"
M.lua_path     = "./?.lua;./shared/?.lua;./service/?.lua;./test/?.lua;../skynet/lualib/?.lua;../skynet/lualib/?/init.lua"
M.lualoader    = "../skynet/lualib/loader.lua"
M.thread       = tonumber(skynet.getenv("thread")) or 4
M.harbor       = 0
M.logpath      = "."
M.logger       = nil

-- ---- CH10_* 覆盖 ----
M.cluster      = os.getenv("CH10_CLUSTER")      or M.cluster
M.node_name    = os.getenv("CH10_NODE_NAME")    or M.node_name
M.cluster_port = tonumber(os.getenv("CH10_CLUSTER_PORT")) or M.cluster_port
M.center_nodes = os.getenv("CH10_CENTERS")      or M.center_nodes
local t = os.getenv("CH10_TEST_TARGET")
if t and t ~= "" then M.test_target = t end

return M
