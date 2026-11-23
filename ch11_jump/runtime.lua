-- runtime.lua — ch11_jump 配置加载（从 skynet 真实加载的 .conf 读业务配置）
--
-- 与 ch10 同理：业务配置（node_name / cluster_port / test_target）由 skynet 启动时解析，
-- 用 skynet.getenv 读取，天然知道当前进程是哪个节点，不依赖易漏传的环境变量。
-- CH10_* 风格的覆盖这里用 CH11_*（其实本议题只用到 test_target / node_name）。

local skynet = require "skynet"

local M = {}

M.cluster      = skynet.getenv("cluster")      or "./conf/clustername.lua"
M.node_name    = skynet.getenv("node_name")    or "node_a"
M.cluster_port = tonumber(skynet.getenv("cluster_port")) or 2541
local tt       = skynet.getenv("test_target")
M.test_target  = (tt and tt ~= "") and tt or nil

-- CH11_* 覆盖
-- 注意：cluster_port 实际由 clustername.lua 的 __nowaiting 地址表决定，cluster.open 只用节点名，
-- 因此 CH11_CLUSTER_PORT 仅影响 M.cluster_port 字段，不会改变监听端口（保留仅为可观测）。
M.node_name    = os.getenv("CH11_NODE_NAME")    or M.node_name
M.cluster_port = tonumber(os.getenv("CH11_CLUSTER_PORT")) or M.cluster_port
local t = os.getenv("CH11_TEST_TARGET")
if t ~= nil then
    -- 显式传入即覆盖；"__none__" 表示不带测试（常驻），供 make run 使用
    M.test_target = (t == "" or t == "__none__") and nil or t
end

return M
