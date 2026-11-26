-- shared/balance.lua — 一致性哈希选节点
--
-- 为什么不用「随机」或「取模」：
--   随机  → 同一个 uid 每次可能落到不同 center，center 侧的本地缓存永远命中不了，
--           而且在线状态要在多个 center 之间同步。
--   取模  → 节点数变化（扩容/宕机摘除）时几乎全部 key 重映射，缓存雪崩。
--   一致性哈希 → 同一 uid 恒定命中同一节点；节点变化时只迁移 1/N 的 key。
--
-- 虚拟节点（vnodes）用来打散分布：真实节点少（2~3 个）时，
-- 直接用节点名哈希会让分布严重倾斜。vnodes 越大越均匀，代价是建表内存。

local M = {}
local Ring = {}
Ring.__index = Ring

-- 一致性哈希的坑：djb2 对短数字串（uid="1".."1000"）的哈希值量级极小，
-- 而虚拟节点字符串（"center1#1"）哈希值分散在 [0,2^32) 全区间；两者量级悬殊
-- 会让二分查找退化——所有 uid 落进同一小段，分布变成 1000/0。
-- 改用 FNV-1a：雪崩特性好，短串与长串都能均匀铺满 [0,2^32)，
-- 实测 1w 个 uid 在两节点上的偏差 ~5%。Lua 5.4 原生 & / ~，无需 bit32。
local function hash(s)
    local hv = 2166136261
    for i = 1, #s do
        hv = (hv ~ s:byte(i)) & 0xffffffff
        hv = (hv * 16777619) & 0xffffffff
    end
    return hv
end

M.hash = hash

function M.new(nodes, vnodes)
    assert(type(nodes) == "table" and #nodes > 0, "nodes must be a non-empty array")
    vnodes = vnodes or 128
    local ring = { points = {}, vnodes = vnodes, nodes = {}, size = 0 }
    for _, n in ipairs(nodes) do
        ring.nodes[#ring.nodes + 1] = n
        for i = 1, vnodes do
            ring.points[#ring.points + 1] = { h = hash(tostring(n) .. "#" .. i), node = n }
        end
    end
    table.sort(ring.points, function(a, b) return a.h < b.h end)
    ring.size = #ring.points
    return setmetatable(ring, Ring)
end

function Ring:pick(key)
    local pts = self.points
    local h   = hash(tostring(key))
    local lo, hi = 1, self.size
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if pts[mid].h < h then lo = mid + 1 else hi = mid end
    end
    return pts[lo].node
end

-- 纯本地的分布统计（测试用，不产生任何跨节点流量）
function Ring:distribution(n, from)
    from = from or 1
    local cnt = {}
    for _, n2 in ipairs(self.nodes) do cnt[n2] = 0 end
    for i = 0, n - 1 do
        local node = self:pick(from + i)
        cnt[node] = (cnt[node] or 0) + 1
    end
    return cnt
end

return M
