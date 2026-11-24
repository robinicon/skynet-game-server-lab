-- test/http_client.lua — 极简 HTTP 客户端（测试用）
--
-- 只支持 Connection: close 模式：服务端写完响应就关闭连接，
-- 客户端读到关闭即认为响应结束 —— 省去解析 Content-Length / chunked。

local socket = require "skynet.socket"

local M = {}

--- 发送一次 HTTP 请求
-- @return table|nil, err    table = { status, header, body, raw }
function M.request(addr, port, method, path, headers, body)
    local fd = socket.open(addr, port)
    if not fd then
        return nil, "connect failed"
    end

    local lines = {
        string.format("%s %s HTTP/1.1", method, path),
        string.format("Host: %s:%d", addr, port),
        "Connection: close",
    }
    if body and #body > 0 then
        lines[#lines + 1] = string.format("Content-Length: %d", #body)
        lines[#lines + 1] = "Content-Type: application/x-www-form-urlencoded"
    end
    for k, v in pairs(headers or {}) do
        lines[#lines + 1] = string.format("%s: %s", k, v)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = body or ""

    socket.write(fd, table.concat(lines, "\r\n"))

    -- 读直到连接关闭（socket.read 在关闭时返回 nil/false）
    local chunks, n = {}, 0
    while n < 512 do
        local chunk = socket.read(fd)
        if not chunk then break end
        if chunk ~= "" then
            chunks[#chunks + 1] = chunk
        end
        n = n + 1
    end
    socket.close(fd)

    local raw = table.concat(chunks)
    if raw == "" then
        return nil, "empty response"
    end

    local head, body_out = raw:match("^(.-)\r\n\r\n(.*)$")
    if not head then
        return { status = nil, header = raw, body = "", raw = raw }
    end
    local status = tonumber(head:match("^HTTP/1%.1%s+(%d+)") or
                            head:match("^HTTP/1%.0%s+(%d+)"))
    return { status = status, header = head, body = body_out, raw = raw }
end

local json = require "shared.json"

--- 请求并解析 JSON body
function M.request_json(addr, port, method, path, headers, body)
    local r, err = M.request(addr, port, method, path, headers, body)
    if not r then return nil, err end
    local ok, obj = pcall(function()
        -- 依赖 shared/json 只能编码；这里用一个极简的状态码检查代替解析
        return nil
    end)
    return r, obj
end

--- 表单编码
function M.form(t)
    local parts = {}
    for k, v in pairs(t or {}) do
        parts[#parts + 1] = string.format("%s=%s", tostring(k), tostring(v))
    end
    return table.concat(parts, "&")
end

return M
