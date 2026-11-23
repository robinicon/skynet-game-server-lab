-- shared/agent_logic_v2.lua — 玩家业务逻辑（v2，模拟"线上部署的新版本"）
--
-- 在 v1 基础上新增了 mp（魔法值）字段，用于演示「热更新添加新字段」。
--
-- 关键：v2 的 process 必须能处理**没有 mp 字段的旧 state**（那些 Agent 是在 v1 时期
-- 创建的，它们的 state 表里根本没有 mp）。这就是"向前兼容迁移"——缺字段就补默认值，
-- 而不是假设字段一定存在导致 nil 崩。

local M = {}
M.VERSION = 2

function M.new_state(uid)
    return { hp = 100, x = 0, level = 1, name = "u" .. uid, mp = 100 }
end

function M.process(state, msg)
    state.x = state.x + 1
    -- 向前兼容：旧 agent 的 state 可能没有 mp，按默认值补齐，不假设字段存在
    state.mp = state.mp or 100
    if type(msg) == "table" and msg.dmg then
        state.hp = state.hp - msg.dmg
    end
    return state
end

return M
