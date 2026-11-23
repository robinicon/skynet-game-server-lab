-- service/http_mgr.lua — HTTP 管理接口服务
--
-- design.md Phase 6：
--   - 独立服务，使用 skynet 内置 HTTP
--   - **不实现 appmgr 管理进程**：管理逻辑在节点外部，
--     本服务只暴露只读指标与受控的 GM 动作，不做拉起/杀掉进程这类操作
--   - HTTP 路由：/health、/gm、/callback
--
-- 安全边界：
--   /health    公开（只读，供负载均衡探活）
--   /gm        需要 token（Authorization: Bearer <token> 或 ?token=）
--   /callback  需要 secret（内部回调，同上）
--
-- 指标聚合：
--   /health 不自己产生业务指标，而是聚合**各业务服务注册上来的 provider**。
--   这样加一个新指标不用改 http_mgr（开闭原则）。

local skynet       = require "skynet"
local socket       = require "skynet.socket"
local httpd        = require "http.httpd"
local sockethelper = require "http.sockethelper"
local json         = require "shared.json"
local service      = require "shared.service"
local error_code   = require "shared.error_code"

local listen_id   = nil
local start_time  = nil

-- 路由表：path → { GET = fn, POST = fn }，fn(header, query, body) -> status, body
local routes      = {}
-- 指标提供者：name → function() -> table
local providers   = {}
-- GM 命令：name → function(args) -> result
local gm_commands = {}

local gm_token    = nil
local cb_secret   = nil

-- ========== 工具 ==========
local function split_path(url)
    local path, query = url:match("^([^?]*)%??(.*)$")
    if path == "" then path = "/" end
    return path, query or ""
end

local function parse_query(q)
    local t = {}
    for kv in q:gmatch("[^&]+") do
        local k, v = kv:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then
            t[skynet.urldecode and skynet.urldecode(k) or k] =
                skynet.urldecode and skynet.urldecode(v) or v
        end
    end
    return t
end

local function parse_form(body)
    -- application/x-www-form-urlencoded
    return parse_query(body or "")
end

local function json_resp(status, obj)
    return status, json.encode(obj), { ["Content-Type"] = "application/json" }
end

local function err_resp(status, msg)
    return json_resp(status, { ok = false, error = msg })
end

--- 鉴权：token 可来自 Authorization 头或 query
local function check_token(header, query, expected)
    if not expected or expected == "" then
        return true          -- 未配置 token 时不鉴权（开发模式）
    end
    local auth = header and (header["authorization"] or header["Authorization"])
    if auth then
        local t = auth:match("^Bearer%s+(.+)$")
        if t == expected then return true end
    end
    if query and query.token == expected then
        return true
    end
    return false
end

-- ========== 路由实现 ==========
routes["/health"] = {
    GET = function(_, _, _)
        -- 聚合所有注册的指标提供者
        local metrics = {}
        local failed = {}
        -- ⚠️ failed 是字符串键的表，`#failed` 恒为 0 —— 必须用计数器
        local n_failed = 0
        for name, fn in pairs(providers) do
            local ok, res = pcall(fn)
            if ok and type(res) == "table" then
                metrics[name] = res
            else
                failed[name] = ok and ("non-table result: " .. tostring(res)) or tostring(res)
                n_failed = n_failed + 1
            end
        end
        local body = {
            ok      = n_failed == 0,
            status  = n_failed == 0 and "healthy" or "degraded",
            node = {
                uptime_s   = math.floor((skynet.time() - start_time) * 100) / 100,
                harbor     = skynet.getenv("harbor") or "0",
                lua_mem_kb = math.floor(collectgarbage("count")),
            },
            metrics = metrics,
        }
        if n_failed > 0 then
            body.provider_errors = failed
        end
        return json_resp(200, body)
    end,
}

routes["/gm"] = {
    POST = function(header, query, body)
        if not check_token(header, query, gm_token) then
            return err_resp(401, "unauthorized: missing or invalid token")
        end
        local args = parse_form(body)
        for k, v in pairs(query) do
            if args[k] == nil then args[k] = v end
        end
        local cmd = args.command or args.cmd
        if not cmd or cmd == "" then
            return err_resp(400, "missing 'command'")
        end
        local fn = gm_commands[cmd]
        if not fn then
            return err_resp(400, "unknown command: " .. tostring(cmd))
        end
        local ok, res = pcall(fn, args)
        if not ok then
            return err_resp(500, "command error: " .. tostring(res))
        end
        return json_resp(200, { ok = true, command = cmd, result = res })
    end,
    -- GET 也允许（便于浏览器/curl 调试），同样需要 token
    GET = function(header, query, _)
        if not check_token(header, query, gm_token) then
            return err_resp(401, "unauthorized: missing or invalid token")
        end
        local cmd = query.command or query.cmd
        if not cmd then
            return json_resp(200, { ok = true, commands = (function()
                local l = {}
                for k in pairs(gm_commands) do l[#l + 1] = k end
                table.sort(l)
                return l
            end)() })
        end
        local fn = gm_commands[cmd]
        if not fn then
            return err_resp(400, "unknown command: " .. tostring(cmd))
        end
        local ok, res = pcall(fn, query)
        if not ok then
            return err_resp(500, "command error: " .. tostring(res))
        end
        return json_resp(200, { ok = true, command = cmd, result = res })
    end,
}

routes["/callback"] = {
    POST = function(header, query, body)
        if not check_token(header, query, cb_secret) then
            return err_resp(401, "unauthorized: missing or invalid secret")
        end
        local args = parse_form(body)
        return json_resp(200, {
            ok = true,
            received = args,
            raw_len  = #(body or ""),
        })
    end,
}

-- ========== 内置 GM 命令 ==========
gm_commands["test"] = function(args)
    return { echo = args.echo or args.message or "pong", at = skynet.time() }
end

gm_commands["reload"] = function(args)
    -- 真实实现会广播热更（见 ch12）；这里只记录意图
    return { module = args.module or "all", scheduled = true }
end

gm_commands["online"] = function()
    local p = providers.login
    local res = p and p() or nil
    return res or { online = 0, note = "no login provider registered" }
end

gm_commands["gc"] = function()
    local before = collectgarbage("count")
    collectgarbage("collect")
    local after = collectgarbage("count")
    return { before_kb = math.floor(before), after_kb = math.floor(after),
             freed_kb = math.floor(before - after) }
end

-- ========== 请求处理 ==========
local function handle_request(fd)
    local readfunc = sockethelper.readfunc(fd)
    local code, url, method, header, body = httpd.read_request(readfunc, 8192)
    if not code then
        -- 解析失败：通常是客户端断开或非法请求
        if url ~= "closed" then
            skynet.error(string.format("[http] bad request: %s", tostring(url)))
        end
        return
    end

    local path, q = split_path(url)
    local query = parse_query(q)
    local route = routes[path]
    local status, resp_body, resp_header = 404, nil, nil

    if route then
        local fn = route[method]
        if fn then
            status, resp_body, resp_header = fn(header, query, body)
        else
            status, resp_body, resp_header = err_resp(405,
                "method not allowed: " .. tostring(method))
        end
    else
        status, resp_body, resp_header = err_resp(404, "no route for " .. tostring(path))
    end

    resp_header = resp_header or {}
    resp_header["Connection"] = "close"

    local ok, err = httpd.write_response(sockethelper.writefunc(fd),
        status, resp_body or "", resp_header)
    if not ok then
        skynet.error(string.format("[http] write response failed: %s", tostring(err)))
    end
end

-- ========== 服务命令 ==========
local handlers = {}

function handlers.init(opts)
    opts = opts or {}
    start_time = skynet.time()
    gm_token = opts.gm_token or os.getenv("CH9_GM_TOKEN") or ""
    cb_secret = opts.cb_secret or os.getenv("CH9_CALLBACK_SECRET") or ""

    local addr  = opts.address or "127.0.0.1"
    local port  = tonumber(opts.port) or 8880
    local backlog = tonumber(opts.backlog) or 128
    -- backlog 必须显式设置：默认 32 会在并发探活时丢弃 SYN（ch4 已验证）
    listen_id = socket.listen(addr, port, backlog)
    skynet.error(string.format("[http] listening on %s:%d (backlog=%d)", addr, port, backlog))

    socket.start(listen_id, function(fd, _)
        socket.start(fd)          -- 必须：启用该 fd 的读
        local ok, err = pcall(handle_request, fd)
        if not ok then
            skynet.error(string.format("[http] handle error: %s", tostring(err)))
        end
        socket.close(fd)
    end)
    return { address = addr, port = port }
end

--- 注册指标提供者
-- @param name          string  指标名（出现在 /health 的 metrics 里）
-- @param provider_addr address 提供指标的服务地址
-- @param cmd           string  调用的命令名（默认 "metrics"）
--
-- ⚠️ 只能传"服务地址 + 命令名"，**不能传函数**：
--    Lua 函数无法跨服务序列化，skynet.call 传函数会在序列化阶段失败，
--    而且是 ERR_INTERNAL 静默降级，很难排查。
function handlers.register_metrics(name, provider_addr, cmd)
    if type(name) ~= "string" then
        return false, "invalid name"
    end
    if not provider_addr then
        return false, "provider_addr required"
    end
    providers[name] = function()
        -- 骨架会把 handler 异常转成 (ERR_INTERNAL, "cmd error: ...") 返回，
        -- 而不是抛错。这里显式转回抛错，让 /health 的 pcall 捕获到真实原因。
        local r = table.pack(skynet.call(provider_addr, "lua", cmd or "metrics"))
        if r[1] == error_code.ERR_INTERNAL then
            error(tostring(r[2] or "provider error"))
        end
        return table.unpack(r, 1, r.n)
    end
    return true
end

function handlers.unregister_metrics(name)
    providers[name] = nil
    return true
end

--- 注册 GM 命令（按模块名，不是按函数）
-- @param name        string 命令名
-- @param module_path string 模块路径，模块需导出 run(args) -> result
--
-- ⚠️ 与指标提供者同理：**不能跨服务传函数**。
--    GM 命令以模块形式提供，服务端内部 require，
--    好处是模块可以被热更替换（见 ch12）。
function handlers.register_gm(name, module_path)
    if type(name) ~= "string" then return false, "invalid name" end
    if type(module_path) ~= "string" then
        return false, "module_path must be a string (function cannot cross services)"
    end
    local ok, mod = pcall(require, module_path)
    if not ok or type(mod) ~= "table" or type(mod.run) ~= "function" then
        return false, "invalid gm module: " .. tostring(mod)
    end
    gm_commands[name] = mod.run
    return true
end

function handlers.list_routes()
    local l = {}
    for p in pairs(routes) do l[#l + 1] = p end
    table.sort(l)
    return l
end

function handlers.list_commands()
    local l = {}
    for k in pairs(gm_commands) do l[#l + 1] = k end
    table.sort(l)
    return l
end

function handlers.stats()
    return {
        routes = handlers.list_routes(),
        commands = handlers.list_commands(),
        providers = (function()
            local l = {}
            for k in pairs(providers) do l[#l + 1] = k end
            table.sort(l)
            return l
        end)(),
        gm_token_set = (gm_token ~= nil and gm_token ~= ""),
        cb_secret_set = (cb_secret ~= nil and cb_secret ~= ""),
    }
end

service.start("http_mgr", handlers, {
    on_init = function()
        start_time = start_time or skynet.time()
    end,
})
