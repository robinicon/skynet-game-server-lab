-- frame_dump.lua —— 生成信封层测试向量（与 frame.py 交叉校验用）
--
-- 用法（在仓库根）：
--   wsl -d Ubuntu -e bash -lc 'lua /mnt/c/workspaces/bookskynet/unity_client/v03_frame/frame_dump.lua'
-- 输出：每行 `<opcode_hex> <ver> <payload_hex>`，供 test_frame.py 逐字节比对。
--
-- 这个脚本存在的意义：证明"C# 客户端 / Lua 网关 / Python 校验器三端用同一份字节定义"，
-- 不是三份各自实现的近似。

local here = (arg and arg[0] or "."):match("^(.*)[/\\]") or "."
package.path = here .. "/?.lua;" .. package.path

local F = require("frame_ref")

local cases = {
    { op = F.make_opcode(0x0006, 0x0001), payload = string.rep("\1", 47) }, -- AUTH_LOGIN_REQ
    { op = F.make_opcode(0x0006, 0x0002), payload = "" },                    -- AUTH_LOGIN_RSP 空包
    { op = F.make_opcode(0x0001, 0x000F), payload = "\10\1\18\3abc" },       -- CLI_ROLE_LIST_REQ
    { op = F.make_opcode(0x0007, 0x0001), payload = string.rep("\255", 30) },-- DG 30B
}

for _, c in ipairs(cases) do
    local f = F.encode(c.op, c.payload)
    local hex = f:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
    io.write(string.format("%08x %d %s\n", c.op, F.MAGIC_V2, hex))
end
