-- shared/json.lua — 最小 JSON 编解码（skynet 不自带 JSON 库）
--
-- 编码：number / string / boolean / nil / array / object，键按字符串排序，输出确定。
-- 解码：支持对象、数组、字符串转义、数字、true/false/null。
-- 约定：形如纯数字的对象键解码回 integer（分片 payload 用 fid 作键）；
--       null 解码为 nil，数组中的 null 会被跳过（本工程数据不使用数组 null）。

local M = {}

local ESCAPE = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function esc(s)
    return (s:gsub('[%z\1-\31\\"]', function(c)
        return ESCAPE[c] or string.format('\\u%04x', c:byte())
    end))
end

-- 判定必须严格：`{[1]=a,[3]=b}` 的 `#t` 在 Lua 里是未定义边界（实测返回 1），
-- 只按 `#t > 0` 判定会被当成数组并静默丢掉 t[3]。
-- delta.values 用 fid 做键（1,3,6...），一旦丢键就是数据错误，所以这里做完整校验。
local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
        if k > n then n = k end
    end
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

-- 强制按 object 编码。
-- 为什么需要：分区数据用 fid 做键，fid 1..n 连续时会被自动判定成数组，
-- 于是同一个字段集合有时下发 `[1000,"acc",1,0]`、有时下发 `{"6":{...}}`，
-- 客户端要按两种形状解析。协议形状必须稳定，所以对 fid 键的表显式打标。
local OBJECT_MT = { __json_object = true }

function M.object(t)
    return setmetatable(t or {}, OBJECT_MT)
end

local function encode(v, out)
    local tv = type(v)
    if tv == "nil" then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("json: NaN/Infinity not supported")
        end
        out[#out + 1] = tostring(v)
    elseif tv == "string" then
        out[#out + 1] = '"' .. esc(v) .. '"'
    elseif tv == "table" then
        -- 注意别写成 `(mt and mt.__json_object) and false or is_array(v)`：
        -- Lua 里 `x and false or y` 在 x 为真时返回 y，等于标记完全失效。
        local mt = getmetatable(v)
        local arr
        if mt and mt.__json_object then
            arr = false
        else
            arr = is_array(v)
        end
        out[#out + 1] = arr and "[" or "{"
        local first = true
        if arr then
            for i = 1, #v do
                if not first then out[#out + 1] = "," end
                first = false
                encode(v[i], out)
            end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = '"' .. esc(tostring(k)) .. '":'
                encode(v[k], out)
            end
        end
        out[#out + 1] = arr and "]" or "}"
    else
        error("json: unsupported type " .. tv)
    end
end

function M.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

local function decode_json(s)
    local pos, n = 1, #s

    local function skip()
        while pos <= n and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local function parse_string()
        pos = pos + 1
        local buf = {}
        while pos <= n do
            local c = s:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                pos = pos + 1
                local e = s:sub(pos, pos)
                local simple = {
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                    f = '\f', n = '\n', r = '\r', t = '\t',
                }
                if simple[e] then
                    buf[#buf + 1] = simple[e]
                    pos = pos + 1
                elseif e == "u" then
                    local hex = s:sub(pos + 1, pos + 4)
                    local code = tonumber(hex, 16)
                    if not code then error("json: bad unicode escape") end
                    buf[#buf + 1] = utf8.char(code)
                    pos = pos + 5
                else
                    error("json: bad escape " .. tostring(e))
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        error("json: unterminated string")
    end

    local function parse_number()
        local start = pos
        while pos <= n and s:sub(pos, pos):match("[-+%.%deE]") do pos = pos + 1 end
        local num = tonumber(s:sub(start, pos - 1))
        if not num then error("json: bad number") end
        return num
    end

    local parse_value
    parse_value = function()
        skip()
        local c = s:sub(pos, pos)
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                skip()
                local k = parse_string()
                skip()
                if s:sub(pos, pos) ~= ":" then error("json: expected colon") end
                pos = pos + 1
                local v = parse_value()
                if k:match("^%d+$") then k = tonumber(k) end
                t[k] = v
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then error("json: expected comma in object") end
            end
        elseif c == "[" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            while true do
                t[#t + 1] = parse_value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                if d ~= "," then error("json: expected comma in array") end
            end
        elseif s:sub(pos, pos + 3) == "true" then
            pos = pos + 4 return true
        elseif s:sub(pos, pos + 4) == "false" then
            pos = pos + 5 return false
        elseif s:sub(pos, pos + 3) == "null" then
            pos = pos + 4 return nil
        end
        return parse_number()
    end

    local value = parse_value()
    skip()
    if pos <= n then error("json: trailing data") end
    return value
end

function M.decode(s)
    if type(s) ~= "string" then return nil, "decode expects string" end
    local ok, res = pcall(decode_json, s)
    if not ok then return nil, tostring(res) end
    return res
end

return M
