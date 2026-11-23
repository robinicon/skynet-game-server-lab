-- shared/json.lua — 极简 JSON 编码器
--
-- skynet 不自带 JSON 库，管理接口只需要"编码"（响应），不需要解析，
-- 所以写一个 60 行的编码器比引入依赖更合适。
--
-- 支持：number / string / boolean / nil / array / object
-- 不支持：循环引用（会栈溢出）、NaN / Infinity（JSON 无此字面量）

local M = {}

local ESCAPE = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function esc(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPE[c] or string.format("\\u%04x", string.byte(c))
    end))
end

--- 判断 table 是数组还是对象
-- 规则：有 [1] 且没有非整数 key → 数组
local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    if n == 0 then return false end       -- 空表当对象，避免 {} 歧义
    return t[1] ~= nil or n == 0
end

local function encode(v, out)
    local t = type(v)
    if t == "nil" then
        out[#out + 1] = "null"
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "number" then
        -- 整数不带小数点
        if math.type(v) == "integer" then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.14g", v)
        end
    elseif t == "string" then
        out[#out + 1] = '"' .. esc(v) .. '"'
    elseif t == "table" then
        if is_array(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            -- 对象：为了让 /health 输出稳定，按 key 排序
            local keys = {}
            for k in pairs(v) do
                if type(k) == "string" or type(k) == "number" then
                    keys[#keys + 1] = tostring(k)
                end
            end
            table.sort(keys)
            out[#out + 1] = "{"
            local first = true
            for _, k in ipairs(keys) do
                if not first then out[#out + 1] = "," end
                first = false
                out[#out + 1] = '"' .. esc(k) .. '":'
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        -- 函数 / userdata 等：输出为字符串，避免编码崩溃
        out[#out + 1] = '"' .. esc(tostring(v)) .. '"'
    end
end

function M.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

return M
