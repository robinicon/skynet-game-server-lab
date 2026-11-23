-- frame_ref.lua —— 信封层服务端参考实现（Lua 5.3+，无外部依赖）
--
-- 与 frame.py 字节级等价：C(f)/C# 客户端、Lua 网关、Python 校验器共用同一份定义。
-- 嵌入 ch4_login/gateway/gated.lua 时只需要替换 netpack 头与 session 尾部这两处。
--
-- 帧格式：[len:u32 BE][ver:u8][opcode:u32 BE][payload]
-- len 不含自身 4 字节；opcode = channel << 16 | id

local M = {}

M.MAGIC_V2    = 0x02
M.MAGIC_V1    = 0x01
M.HEADER_LEN  = 9
M.MAX_FRAME   = 1024 * 1024

function M.make_opcode(channel, id)
    assert(channel >= 0 and channel <= 0xFFFF, "channel out of range")
    assert(id >= 0 and id <= 0xFFFF, "id out of range")
    return channel * 0x10000 + id
end

function M.encode(opcode, payload, ver)
    ver = ver or M.MAGIC_V2
    payload = payload or ""
    local body_len = 1 + 4 + #payload
    assert(body_len <= M.MAX_FRAME, "frame too large")
    return string.pack(">I4BI4", body_len, ver, opcode) .. payload
end

-- 返回 opcode, payload, ver；失败返回 nil, errcode
function M.decode(buf)
    if #buf < M.HEADER_LEN then return nil, "FRAME_TOO_SHORT" end
    local body_len, ver, opcode = string.unpack(">I4BI4", buf)
    if body_len < 5 or body_len > M.MAX_FRAME then return nil, "BAD_LENGTH_FIELD" end
    if ver ~= M.MAGIC_V1 and ver ~= M.MAGIC_V2 then return nil, "BAD_VERSION" end
    if #buf ~= 4 + body_len then return nil, "LENGTH_MISMATCH" end
    return opcode, buf:sub(M.HEADER_LEN + 1), ver
end

-- 读版本字节（固定偏移 4）。这是 C-21 的修复形态，不要用 buf:byte(1) 判别。
function M.sniff(buf)
    if #buf < 5 then return nil, "FRAME_TOO_SHORT" end
    return buf:byte(5)
end

-- 粘包切分：netpack 一次可能给出多帧
function M.split_stream(stream)
    local frames, off = {}, 1
    while off <= #stream do
        if off + 4 > #stream then return nil, "TRUNCATED_HEADER" end
        local body_len = string.unpack(">I4", stream, off)
        if body_len < 5 or body_len > M.MAX_FRAME then return nil, "BAD_LENGTH_FIELD" end
        local stop = off + 4 + body_len - 1
        if stop > #stream then return nil, "TRUNCATED_BODY" end
        local ok, opcode, payload, ver = pcall(M.decode, stream:sub(off, stop))
        if not ok or not opcode then return nil, ok and payload or "DECODE_FAILED" end
        frames[#frames + 1] = { opcode = opcode, payload = payload, ver = ver }
        off = stop + 1
    end
    return frames
end

return M
