-- runtime.lua — ch12 配置加载（从 skynet 真实加载的 .conf 读业务配置）
--
-- 与 ch10 / ch11 同理：角色/测试目标由 skynet 启动时解析，用 skynet.getenv 读取，
-- 不依赖易漏传的环境变量。CH12_* 仅作为单测调参覆盖。

local skynet = require "skynet"

local M = {}

M.node_name   = skynet.getenv("node_name") or "node_a"
M.test_target = skynet.getenv("test_target") or ""

-- CH12_* 覆盖
M.node_name   = os.getenv("CH12_NODE_NAME") or M.node_name
local t = os.getenv("CH12_TEST_TARGET")
if t ~= nil then
    -- 显式传入即覆盖；"" 或 "__none__" 表示不带测试（常驻），供 make run 使用
    M.test_target = (t == "" or t == "__none__") and "" or t
end

return M
