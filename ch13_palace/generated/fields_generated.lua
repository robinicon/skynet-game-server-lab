-- GENERATED FILE - do not edit. Source: conf/schema.xlsx
local M = {}
M.version = 1
M.by_id = {
    [1] = { fid=1, name="uid", type="int", partition="base", persist="index", replicate="snapshot" },
    [2] = { fid=2, name="account", type="string", partition="base", persist="index", replicate="snapshot" },
    [3] = { fid=3, name="level", type="int", partition="base", persist="index", replicate="delta" },
    [4] = { fid=4, name="gold", type="int", partition="base", persist="index", replicate="delta" },
    [5] = { fid=5, name="vip", type="int", partition="base", persist="lazy", replicate="delta" },
    [6] = { fid=6, name="heroes", type="map", partition="hero", persist="blob", replicate="delta" },
    [7] = { fid=7, name="bag", type="map", partition="item", persist="blob", replicate="delta" },
    [8] = { fid=8, name="missions", type="map", partition="mission", persist="lazy", replicate="on_demand" },
    [9] = { fid=9, name="activity", type="map", partition="activity", persist="lazy", replicate="on_demand" },
    [10] = { fid=10, name="last_login", type="int", partition="base", persist="blob", replicate="none" },
    [11] = { fid=11, name="zhanli", type="int", partition="base", persist="derived", replicate="delta" },
    [12] = { fid=12, name="client_flags", type="map", partition="base", persist="transient", replicate="none" },
    [13] = { fid=13, name="silver", type="int", partition="base", persist="index", replicate="delta" },
}
M.by_name = {
    uid = 1,
    account = 2,
    level = 3,
    gold = 4,
    vip = 5,
    heroes = 6,
    bag = 7,
    missions = 8,
    activity = 9,
    last_login = 10,
    zhanli = 11,
    client_flags = 12,
    silver = 13,
}
M.partitions = {
    activity = { 9 },
    base = { 1, 2, 3, 4, 5, 10, 11, 12, 13 },
    hero = { 6 },
    item = { 7 },
    mission = { 8 },
}
M.index_fields = {
    1,
    2,
    3,
    4,
    13,
}
return M
