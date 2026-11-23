-- lualib/skynet/crypt.lua — 桥接：本仓库 skynet 的 crypt.so 只导出 luaopen_skynet_crypt
--
-- `../skynet/lualib/http/websocket.lua` 首行是 `require "skynet.crypt"`，
-- 而标准 skynet 的该模块是 C 扩展 `luaclib/skynet/crypt.so`（入口 luaopen_skynet_crypt）。
-- 本仓库把同一个 .so 放成了平铺的 `luaclib/crypt.so`，于是：
--   require "skynet.crypt" → 找不到 luaopen_crypt / 文件不存在
--   require "crypt"        → 找到文件，但 .so 里没有 luaopen_crypt
-- 实测 `nm -D` 只导出 luaopen_skynet_crypt 与 luaopen_client_crypt。
--
-- 因此这里按 cpath 定位文件，再显式指定入口加载。不改动 skynet 库本身。
--
-- 依赖：conf/skynet.conf 的 lua_path 需包含 `./lualib/?.lua`，
--       lua_cpath 需包含 `../skynet/luaclib/?.so`

local path = package.searchpath("crypt", package.cpath)
if not path then
    error("crypt.so not found in package.cpath: " .. tostring(package.cpath))
end

local open = assert(package.loadlib(path, "luaopen_skynet_crypt"))
return open()
