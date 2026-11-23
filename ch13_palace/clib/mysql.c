/*
 * clib/mysql.c - 阶段 2：skynet Lua 的同步 MySQL 客户端扩展
 *
 * 只暴露最小接口，DB 服务是串行单点，同步调用不破坏抽象存储契约：
 *   mysql.connect(host, port, user, password, database) -> conn (userdata)
 *   conn:query(sql)   -> { {col1=val, col2=val, ...}, ... }  (SELECT)
 *   conn:exec(sql)    -> affected_rows                       (INSERT/UPDATE/DDL)
 *   conn:insert_id()  -> last insert id
 *   conn:close()
 *   conn.connected    -> bool (field)
 *
 * 出错一律 luaL_error，由 Lua 侧 pcall 捕获。
 * 列值统一以字符串返回（数值由 Lua 自己 tonumber），NULL 返回 nil。
 */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <mysql/mysql.h>
#include <string.h>

#define MYSQL_MT "ch13.mysql.conn"

static MYSQL **check_conn(lua_State *L, int idx) {
    return (MYSQL **)luaL_checkudata(L, idx, MYSQL_MT);
}

static int l_connect(lua_State *L) {
    const char *host = luaL_checkstring(L, 1);
    int port = (int)luaL_checkinteger(L, 2);
    const char *user = luaL_checkstring(L, 3);
    const char *pass = luaL_checkstring(L, 4);
    const char *db = luaL_checkstring(L, 5);

    MYSQL *m = mysql_init(NULL);
    if (!m) return luaL_error(L, "mysql_init failed");
    unsigned int timeout = 3;
    mysql_options(m, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    if (!mysql_real_connect(m, host, user, pass, db, port, NULL, 0)) {
        const char *err = mysql_error(m);
        mysql_close(m);
        return luaL_error(L, "mysql connect failed: %s", err);
    }
    mysql_set_character_set(m, "utf8mb4");

    MYSQL **ud = (MYSQL **)lua_newuserdatauv(L, sizeof(MYSQL *), 0);
    *ud = m;
    luaL_getmetatable(L, MYSQL_MT);
    lua_setmetatable(L, -2);
    return 1;
}

static int l_query(lua_State *L) {
    MYSQL **ud = check_conn(L, 1);
    size_t len = 0;
    const char *sql = luaL_checklstring(L, 2, &len);
    if (mysql_real_query(*ud, sql, (unsigned long)len) != 0) {
        return luaL_error(L, "mysql query failed: %s", mysql_error(*ud));
    }
    MYSQL_RES *res = mysql_store_result(*ud);
    if (!res) {
        if (mysql_field_count(*ud) == 0) {
            lua_newtable(L);   /* 非 SELECT 返回空表，语义统一 */
            return 1;
        }
        return luaL_error(L, "mysql store_result failed: %s", mysql_error(*ud));
    }

    unsigned int ncols = mysql_num_fields(res);
    MYSQL_FIELD *fields = mysql_fetch_fields(res);
    lua_createtable(L, 0, 0);
    unsigned long rownum = 0;
    MYSQL_ROW row;
    while ((row = mysql_fetch_row(res)) != NULL) {
        unsigned long *lengths = mysql_fetch_lengths(res);
        lua_createtable(L, 0, ncols);
        for (unsigned int c = 0; c < ncols; c++) {
            if (row[c]) lua_pushlstring(L, row[c], lengths[c]);
            else lua_pushnil(L);
            lua_setfield(L, -2, fields[c].name);
        }
        lua_rawseti(L, -2, ++rownum);
    }
    mysql_free_result(res);
    return 1;
}

static int l_exec(lua_State *L) {
    MYSQL **ud = check_conn(L, 1);
    size_t len = 0;
    const char *sql = luaL_checklstring(L, 2, &len);
    if (mysql_real_query(*ud, sql, (unsigned long)len) != 0) {
        return luaL_error(L, "mysql exec failed: %s", mysql_error(*ud));
    }
    /* 吃掉可能的结果集，保证后续命令可用 */
    MYSQL_RES *res = mysql_store_result(*ud);
    if (res) mysql_free_result(res);
    my_ulonglong affected = mysql_affected_rows(*ud);
    lua_pushinteger(L, (lua_Integer)affected);
    return 1;
}

static int l_insert_id(lua_State *L) {
    MYSQL **ud = check_conn(L, 1);
    lua_pushinteger(L, (lua_Integer)mysql_insert_id(*ud));
    return 1;
}

static int l_close(lua_State *L) {
    MYSQL **ud = check_conn(L, 1);
    if (*ud) {
        mysql_close(*ud);
        *ud = NULL;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_gc(lua_State *L) {
    MYSQL **ud = luaL_testudata(L, 1, MYSQL_MT);
    if (ud && *ud) {
        mysql_close(*ud);
        *ud = NULL;
    }
    return 0;
}

static int l_escape(lua_State *L) {
    MYSQL **ud = check_conn(L, 1);
    size_t len = 0;
    const char *s = luaL_checklstring(L, 2, &len);
    char *buf = (char *)malloc(len * 2 + 1);
    if (!buf) return luaL_error(L, "mysql escape: out of memory");
    mysql_real_escape_string(*ud, buf, s, (unsigned long)len);
    lua_pushstring(L, buf);
    free(buf);
    return 1;
}

static const luaL_Reg conn_methods[] = {
    { "query",      l_query },
    { "exec",       l_exec },
    { "insert_id",  l_insert_id },
    { "escape",     l_escape },
    { "close",      l_close },
    { NULL, NULL }
};

static const luaL_Reg module_funcs[] = {
    { "connect", l_connect },
    { NULL, NULL }
};

int luaopen_mysql(lua_State *L) {
    luaL_newmetatable(L, MYSQL_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, conn_methods, 0);
    lua_pushcfunction(L, l_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    lua_newtable(L);
    luaL_setfuncs(L, module_funcs, 0);
    return 1;
}
