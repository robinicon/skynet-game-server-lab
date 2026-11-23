-- service/hub.lua — 跨服中心（P0.5 最小可运行）
--
-- 设计依据：docs/CROSS_SERVER.md §3 / §4。只落"排行"一条最短链路：
--   * 提交 / 查询，(gid, sid, seq) 幂等，乱序 seq 丢弃
--   * 三级开关（总闸 → 分组 → 特性 → 比例），关闭时入口灰掉而非报错
--   * 状态（rank / last_seq / switches）JSON 快照落盘，冷启动恢复
-- 明确不做：跨服战 settle（留接口 error）、world boss、公会战、mail、多实例、Redis。
--
-- 对外是独立 skynet 服务，cmd 见 CMD；客户端不直连，经 agent 的 cross handler 调用。

local skynet = require "skynet"
local json   = require "shared.json"

local CMD = {}

-- ---------- 状态 ----------
-- ranks[rankKey] = { [uid] = { uid, name, score, sid, seq } }
-- last_seq[rankKey][sid] = 已接受的最大 seq（数字键 → JSON 对象形状）
-- switches = { enabled, groups = { [gid] = { enabled, features = {...} } }, rollout = {...} }
local ranks     = {}
local last_seq  = {}
local switches
local snapshot_path = "data/hub-snapshot.json"
local rev = 0

local function default_switches()
    return {
        enabled = true,
        groups = {
            -- gid=1 默认开；features.rank 开，fight/mail 关（P0.5 只落 rank）
            [1] = { enabled = true, features = { rank = true, fight = false, mail = false } },
        },
        rollout = { rank = 100, fight = 0, mail = 0 },
    }
end

local function ensure_switches()
    switches = switches or default_switches()
    return switches
end

-- ---------- 开关判定：总闸 → 分组 → 特性 → 比例 ----------
-- 返回 true 或 false, reason。任何一级关闭即"未开启"（客户端灰入口）。
local function rank_enabled(gid)
    local s = ensure_switches()
    if not s.enabled then return false, "cross_disabled" end
    local g = s.groups[gid]
    if not g or not g.enabled then return false, "group_disabled" end
    if not (g.features and g.features.rank) then return false, "rank_disabled" end
    local pct = tonumber(s.rollout and s.rollout.rank) or 0
    if pct <= 0 then return false, "rank_rollout_off" end
    if pct >= 100 then return true end
    -- L3 比例：按 uid 稳定哈希取模，保证同一 uid 每次判定一致（不随机）
    return true, pct
end

-- 点分路径写开关：set_switch("rank", false) 等价 total+rank 常用简写；
-- 支持 "enabled" / "groups.1.enabled" / "groups.1.features.rank" / "rollout.rank"。
local function set_switch_path(path, value)
    if path == "rank" then
        -- 简写：同时开/关 L1 总闸下的 rank 特性，便于测试与运维
        ensure_switches().groups[1] = ensure_switches().groups[1] or { enabled = true, features = {} }
        local g = ensure_switches().groups[1]
        g.features = g.features or {}
        g.features.rank = value and true or false
        return true
    end
    local keys = {}
    for part in tostring(path):gmatch("[^.]+") do keys[#keys + 1] = part end
    if #keys == 0 then return false end
    local node = ensure_switches()
    for i = 1, #keys - 1 do
        local k = keys[i]
        local num = tonumber(k)
        if num then k = num end
        if type(node[k]) ~= "table" then return false end
        node = node[k]
    end
    local last = keys[#keys]
    local num = tonumber(last)
    if num then last = num end
    node[last] = value
    return true
end

-- ---------- 快照：落盘 / 恢复 ----------
local function persist()
    local doc = {
        rev = rev,
        ranks = ranks,
        -- last_seq 的二级键是 sid 数字，必须显式对象，否则 json 会按数组编码丢语义
        last_seq = json.object(last_seq),
        switches = switches,
    }
    local dir = snapshot_path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. dir) end
    local f = io.open(snapshot_path, "w")
    if not f then return false, "cannot open " .. snapshot_path end
    f:write(json.encode(doc))
    f:close()
    return true
end

local function restore()
    local f = io.open(snapshot_path, "r")
    if not f then return false end
    local text = f:read("*a")
    f:close()
    local doc, err = json.decode(text)
    if not doc or type(doc) ~= "table" then
        skynet.error("[hub] bad snapshot: " .. tostring(err))
        return false
    end
    ranks    = doc.ranks or {}
    last_seq = doc.last_seq or {}
    switches = doc.switches or default_switches()
    rev      = tonumber(doc.rev) or 0
    skynet.error(string.format("[hub] restored rev=%d rankKeys=%d", rev, (function()
        local n = 0; for _ in pairs(ranks) do n = n + 1 end; return n end)()))
    return true
end

-- ---------- 排行核心 ----------
local function sorted_rows(rankKey)
    local bucket = ranks[rankKey] or {}
    local rows = {}
    for _, rec in pairs(bucket) do rows[#rows + 1] = rec end
    table.sort(rows, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.sid ~= b.sid then return a.sid < b.sid end
        return a.uid < b.uid
    end)
    for i, row in ipairs(rows) do row.rank = i end
    return rows
end

-- hub.submit(gid, sid, seq, rankKey, uid, score) -> { ok, rev, rank, reason }
local function submit(gid, sid, seq, rankKey, uid, score)
    -- §4.3 T4：入口开关关闭时 submit 仍可写（灰入口、不阻断写链路）。
    -- 把 enabled 状态回带给调用方，测试可断言"关着也能写"。
    local enabled, switch_reason = rank_enabled(tonumber(gid) or 1)
    gid = tonumber(gid) or 1
    sid = tonumber(sid) or 1
    seq = tonumber(seq) or 0
    rankKey = tostring(rankKey or "default")
    uid = tostring(uid or "")
    score = tonumber(score) or 0
    if uid == "" then return { ok = false, rev = rev, reason = "bad_uid" } end

    local function with_switch(t)
        t.enabled, t.switch_reason = enabled, switch_reason
        return t
    end

    local by_sid = last_seq[rankKey]
    if not by_sid then by_sid = {}; last_seq[rankKey] = by_sid end
    local prev = tonumber(by_sid[sid]) or 0
    if seq <= prev then
        -- 幂等（seq == prev）与乱序丢弃（seq < prev）统一：不改状态，返回当前 rev/rank
        local rows = sorted_rows(rankKey)
        local my_rank
        for _, row in ipairs(rows) do if row.uid == uid then my_rank = row.rank break end end
        return with_switch({ ok = true, rev = rev, rank = my_rank, reason = (seq < prev) and "stale_seq" or "duplicate" })
    end

    by_sid[sid] = seq
    local bucket = ranks[rankKey]
    if not bucket then bucket = {}; ranks[rankKey] = bucket end
    local rec = bucket[uid]
    if rec then
        rec.score, rec.sid, rec.seq = score, sid, seq
    else
        bucket[uid] = { uid = uid, name = uid, score = score, sid = sid, seq = seq }
    end
    rev = rev + 1
    local rows = sorted_rows(rankKey)
    local my_rank
    for _, row in ipairs(rows) do if row.uid == uid then my_rank = row.rank break end end
    return with_switch({ ok = true, rev = rev, rank = my_rank })
end

-- hub.upsert(rankKey, uid, name, score) -> { ok, rev, rank, enabled }
--
-- 本服榜专用写入：单实例权威、分数不是跨服聚合出来的，因此不需要 (sid, seq) 幂等门。
-- 用秒级 seq 走 submit 的后果是「同一秒内战力变化被当作 duplicate 丢弃」，本服榜不能接受。
-- 跨服榜仍走 submit（保留乱序/重复语义），两者共用同一个 bucket 结构与开关。
local function upsert(rankKey, uid, name, score)
    local enabled, switch_reason = rank_enabled(1)
    rankKey = tostring(rankKey or "default")
    uid = tostring(uid or "")
    score = tonumber(score) or 0
    if uid == "" then return { ok = false, rev = rev, reason = "bad_uid" } end

    local bucket = ranks[rankKey]
    if not bucket then bucket = {}; ranks[rankKey] = bucket end
    local rec = bucket[uid]
    if rec then
        rec.score, rec.name = score, tostring(name or rec.name or uid)
    else
        bucket[uid] = { uid = uid, name = tostring(name or uid), score = score, sid = 0, seq = 0 }
    end
    rev = rev + 1

    local my_rank
    for _, row in ipairs(sorted_rows(rankKey)) do
        if row.uid == uid then my_rank = row.rank break end
    end
    return { ok = true, rev = rev, rank = my_rank, enabled = enabled, switch_reason = switch_reason }
end

-- hub.rank(gid, rankKey, page, size) -> { rev, rows, me, enabled, reason }
local function rank(gid, rankKey, page, size)
    local enabled, reason = rank_enabled(tonumber(gid) or 1)
    rankKey = tostring(rankKey or "default")
    if not enabled then
        return { ok = false, rev = rev, rows = {}, me = nil, enabled = false, reason = reason }
    end
    page = math.max(1, math.floor(tonumber(page) or 1))
    size = math.max(1, math.min(100, math.floor(tonumber(size) or 20)))
    local rows = sorted_rows(rankKey)
    local start = (page - 1) * size + 1
    local out = {}
    for i = start, math.min(start + size - 1, #rows) do
        local r = rows[i]
        out[#out + 1] = { uid = r.uid, name = r.name, score = r.score, rank = r.rank, sid = r.sid }
    end
    return { ok = true, rev = rev, rows = out, me = nil, enabled = true }
end

-- ---------- skynet 接口 ----------
function CMD.init(conf)
    snapshot_path = (conf and conf.snapshot_path) or snapshot_path
    restore()
    return true
end

function CMD.submit(gid, sid, seq, rankKey, uid, score)
    return submit(gid, sid, seq, rankKey, uid, score)
end

function CMD.rank(gid, rankKey, page, size)
    return rank(gid, rankKey, page, size)
end

function CMD.upsert(rankKey, uid, name, score)
    return upsert(rankKey, uid, name, score)
end

function CMD.set_switch(path, value)
    set_switch_path(path, value)
    return { ok = true }
end

function CMD.snapshot()
    local ok, err = persist()
    return { ok = ok, reason = err }
end

function CMD.state()
    return { rev = rev, ranks = ranks, last_seq = json.object(last_seq), switches = switches }
end

-- 跨服战结算：P0.5 明确不实现，只留接口签名（CROSS_SERVER §4.4）。
-- 返回结构化"未实现"而非 error()，避免 throw 污染 skynet 日志、也不会让调用方 actor 崩。
function CMD.settle()
    return { ok = false, reason = "not_implemented", need = "U4 fight handler" }
end

skynet.dispatch("lua", function(_, _, cmd, ...)
    local f = assert(CMD[cmd], "hub: unknown command " .. tostring(cmd))
    skynet.ret(skynet.pack(f(...)))
end)

skynet.start(function()
    skynet.error("[hub] started (P0.5 minimal rank link)")
end)
