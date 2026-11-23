-- runtime.lua — ch13_palace 运行时配置加载：conf > env 覆盖

local M = {
    root           = "./",
    snapshot_path  = "data/snapshot.json",
    hub_snapshot_path = "data/hub-snapshot.json",  -- P0.5：跨服 hub 状态快照
    test_target    = nil,
    replay_file    = nil,   -- 阶段 5：离线回放样本（对账）
    replay_out     = "data/replay_out.json",
    gate_address   = "127.0.0.1",
    gate_port      = "9813",
    -- P0：WebSocket 网关（Unity / 小游戏）
    ws_gate_address = "127.0.0.1",
    ws_gate_port    = "9814",
    ws_enabled      = "true",
    maxclient      = "256",
    backlog        = "256",
    session_grace  = "300",   -- 断线重连窗口，单位 0.01s（默认 3 秒）
    db_driver      = "memory",
    db_host        = "127.0.0.1",
    db_port        = "3306",
    db_user        = "dev",
    db_password    = "dev123",
    db_name        = "ch13_palace",
}

local function parse_conf(path)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local cleaned = line:gsub("%s*%-%-.*$", ""):gsub("%s*#.*$", ""):gsub("%s+$", "")
        if cleaned ~= "" then
            local key, val = cleaned:match("^([%w_]+)%s*=%s*(.+)$")
            if key and val then
                val = val:gsub("%s+$", ""):gsub("^['\"]", ""):gsub("['\"]$", "")
                M[key] = val
            end
        end
    end
    f:close()
end

local function merge_env()
    local t = os.getenv("CH13_TEST_TARGET")
    if t and t ~= "" and t ~= "__none__" then M.test_target = t end
    local p = os.getenv("CH13_SNAPSHOT")
    if p and p ~= "" then M.snapshot_path = p end
    local hp = os.getenv("CH13_HUB_SNAPSHOT")
    if hp and hp ~= "" then M.hub_snapshot_path = hp end
    local gp = os.getenv("CH13_GATE_PORT")
    if gp and gp ~= "" then M.gate_port = gp end
    local ga = os.getenv("CH13_GATE_ADDRESS")
    if ga and ga ~= "" then M.gate_address = ga end
    local wp = os.getenv("CH13_WS_PORT")
    if wp and wp ~= "" then M.ws_gate_port = wp end
    local wa = os.getenv("CH13_WS_ADDRESS")
    if wa and wa ~= "" then M.ws_gate_address = wa end
    local we = os.getenv("CH13_WS_ENABLED")
    if we and we ~= "" then M.ws_enabled = we end
    local sg = os.getenv("CH13_SESSION_GRACE")
    if sg and sg ~= "" then M.session_grace = sg end
    local dd = os.getenv("CH13_DB_DRIVER")
    if dd and dd ~= "" then M.db_driver = dd end
    local dh = os.getenv("CH13_DB_HOST")
    if dh and dh ~= "" then M.db_host = dh end
    local dp = os.getenv("CH13_DB_PORT")
    if dp and dp ~= "" then M.db_port = dp end
    local du = os.getenv("CH13_DB_USER")
    if du and du ~= "" then M.db_user = du end
    local dpass = os.getenv("CH13_DB_PASSWORD")
    if dpass and dpass ~= "" then M.db_password = dpass end
    local dn = os.getenv("CH13_DB_NAME")
    if dn and dn ~= "" then M.db_name = dn end
    local rf = os.getenv("CH13_REPLAY_FILE")
    if rf and rf ~= "" then M.replay_file = rf end
    local ro = os.getenv("CH13_REPLAY_OUT")
    if ro and ro ~= "" then M.replay_out = ro end
end

parse_conf("conf/skynet.conf")
merge_env()

return M
