-- shared/agent_logic.lua — 玩家业务逻辑（v1，可热更模块）
--
-- 这是 Agent 真正"算数"的逻辑，被 agent_reconnect 通过 require 加载。热更新时只需
-- 切换 require 的模块路径（见 agent_logic_v2.lua）并广播 reload，无需重启进程。
--
-- 设计上把"会变的逻辑"和"不会变的骨架（agent_reconnect）"分离，热更只动 logic。

local M = {}
M.VERSION = 1

function M.new_state(uid)
    return { hp = 100, x = 0, level = 1, name = "u" .. uid }
end

function M.process(state, msg)
    state.x = state.x + 1
    if type(msg) == "table" and msg.dmg then
        state.hp = state.hp - msg.dmg
    end
    return state
end

return M
