/*
 * ecs_high.c — 高频 ECS 的 Lua 绑定
 *
 * 编译：make -C ch6_ecs   （产物 luaclib/ecs_high.so）
 *
 * 对外 Lua API：
 *   local ecs = require "ecs_high"
 *   local w = ecs.new(1024)
 *   w:add(eid, px, py, vx, vy, hp) -> slot
 *   w:del(eid)                     -> bool
 *   w:has(eid)                     -> bool
 *   w:get(eid)                     -> px, py, hp, slot
 *   w:set_velocity(eid, vx, vy)    -> bool
 *   w:damage_all(dmg)
 *   w:update(dt, bound)            -> 单帧 tick
 *   w:bench(dt, bound, ticks)      -> 总耗时纳秒（C 内部计时，避免 Lua 侧开销）
 *   w:count()                      -> n
 *   w:capacity()                   -> cap
 */

#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "ecs_high.h"

#define MT_NAME "ECS_HIGH_WORLD"

/* ---------------- 内部实现 ---------------- */

static void ensure_sparse(ecs_world *w, uint32_t eid) {
    if (eid < w->sparse_cap) return;
    uint32_t newcap = w->sparse_cap ? w->sparse_cap : 64;
    while (newcap <= eid) newcap *= 2;
    int32_t *ns = (int32_t *)realloc(w->sparse, sizeof(int32_t) * newcap);
    if (!ns) return;   /* 分配失败：调用方会看到 has()==false */
    for (uint32_t i = w->sparse_cap; i < newcap; i++) ns[i] = -1;
    w->sparse = ns;
    w->sparse_cap = newcap;
}

static int ensure_dense(ecs_world *w, uint32_t need) {
    if (need <= w->cap) return 1;
    uint32_t newcap = w->cap ? w->cap : 64;
    while (newcap < need) newcap *= 2;

    uint32_t *ne = (uint32_t *)realloc(w->eid, sizeof(uint32_t) * newcap);
    float *npx = (float *)realloc(w->px, sizeof(float) * newcap);
    float *npy = (float *)realloc(w->py, sizeof(float) * newcap);
    float *nvx = (float *)realloc(w->vx, sizeof(float) * newcap);
    float *nvy = (float *)realloc(w->vy, sizeof(float) * newcap);
    int32_t *nhp = (int32_t *)realloc(w->hp, sizeof(int32_t) * newcap);
    int32_t *nmh = (int32_t *)realloc(w->maxhp, sizeof(int32_t) * newcap);

    if (!ne || !npx || !npy || !nvx || !nvy || !nhp || !nmh) {
        /* 部分成功也要保证结构体自洽：只提交全部成功的一组 */
        free(ne); free(npx); free(npy); free(nvx); free(nvy); free(nhp); free(nmh);
        return 0;
    }
    w->eid = ne; w->px = npx; w->py = npy;
    w->vx = nvx; w->vy = nvy; w->hp = nhp; w->maxhp = nmh;
    w->cap = newcap;
    return 1;
}

ecs_world *ecs_world_new(uint32_t cap) {
    ecs_world *w = (ecs_world *)calloc(1, sizeof(ecs_world));
    if (!w) return NULL;
    if (cap < 8) cap = 8;
    if (!ensure_dense(w, cap)) { free(w); return NULL; }
    ensure_sparse(w, cap);
    if (!w->sparse) { ecs_world_free(w); return NULL; }
    return w;
}

void ecs_world_free(ecs_world *w) {
    if (!w) return;
    free(w->sparse); free(w->eid);
    free(w->px); free(w->py); free(w->vx); free(w->vy);
    free(w->hp); free(w->maxhp);
    free(w);
}

int32_t ecs_slot(ecs_world *w, uint32_t eid) {
    if (eid >= w->sparse_cap) return -1;
    return w->sparse[eid];
}

int ecs_has(ecs_world *w, uint32_t eid) {
    return ecs_slot(w, eid) >= 0;
}

int ecs_add(ecs_world *w, uint32_t eid,
            float px, float py, float vx, float vy, int32_t hp) {
    ensure_sparse(w, eid);
    if (!w->sparse || eid >= w->sparse_cap) return 0;
    if (w->sparse[eid] >= 0) return 0;              /* 已存在 */
    if (!ensure_dense(w, w->n + 1)) return 0;

    uint32_t slot = w->n;
    w->eid[slot]   = eid;
    w->px[slot]    = px;
    w->py[slot]    = py;
    w->vx[slot]    = vx;
    w->vy[slot]    = vy;
    w->hp[slot]    = hp;
    w->maxhp[slot] = hp;
    w->sparse[eid] = (int32_t)slot;
    w->n++;
    return 1;
}

int ecs_del(ecs_world *w, uint32_t eid) {
    int32_t slot = ecs_slot(w, eid);
    if (slot < 0) return 0;

    uint32_t last = w->n - 1;
    if ((uint32_t)slot != last) {
        /* swap-remove：把末尾元素搬到删除位，保持数组紧凑 */
        uint32_t moved = w->eid[last];
        w->eid[slot]   = moved;
        w->px[slot]    = w->px[last];
        w->py[slot]    = w->py[last];
        w->vx[slot]    = w->vx[last];
        w->vy[slot]    = w->vy[last];
        w->hp[slot]    = w->hp[last];
        w->maxhp[slot] = w->maxhp[last];
        w->sparse[moved] = slot;
    }
    w->sparse[eid] = -1;
    w->n--;
    return 1;
}

void ecs_update(ecs_world *w, float dt, float bound) {
    uint32_t n = w->n;
    float *px = w->px, *py = w->py, *vx = w->vx, *vy = w->vy;
    int32_t *hp = w->hp, *maxhp = w->maxhp;

    for (uint32_t i = 0; i < n; i++) {
        float x = px[i] + vx[i] * dt;
        float y = py[i] + vy[i] * dt;

        if (x < 0.0f)      { x = 0.0f;      vx[i] = -vx[i]; }
        else if (x > bound) { x = bound;    vx[i] = -vx[i]; }
        if (y < 0.0f)      { y = 0.0f;      vy[i] = -vy[i]; }
        else if (y > bound) { y = bound;    vy[i] = -vy[i]; }

        px[i] = x;
        py[i] = y;

        if (hp[i] < maxhp[i]) hp[i]++;
    }
}

void ecs_damage_all(ecs_world *w, int32_t dmg) {
    for (uint32_t i = 0; i < w->n; i++) {
        w->hp[i] -= dmg;
        if (w->hp[i] < 0) w->hp[i] = 0;
    }
}

/* ---------------- Lua 绑定 ---------------- */

static int lnew(lua_State *L) {
    uint32_t cap = (uint32_t)luaL_optinteger(L, 1, 1024);
    ecs_world *w = ecs_world_new(cap);
    if (!w) return luaL_error(L, "ecs.new: out of memory");
    ecs_world **ud = (ecs_world **)lua_newuserdatauv(L, sizeof(ecs_world *), 0);
    *ud = w;
    luaL_getmetatable(L, MT_NAME);
    lua_setmetatable(L, -2);
    return 1;
}

static int lgc(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    if (*ud) { ecs_world_free(*ud); *ud = NULL; }
    return 0;
}

static int ladd(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    ecs_world *w = *ud;
    uint32_t eid = (uint32_t)luaL_checkinteger(L, 2);
    float px = (float)luaL_checknumber(L, 3);
    float py = (float)luaL_checknumber(L, 4);
    float vx = (float)luaL_optnumber(L, 5, 0.0);
    float vy = (float)luaL_optnumber(L, 6, 0.0);
    int32_t hp = (int32_t)luaL_optinteger(L, 7, 100);

    if (!ecs_add(w, eid, px, py, vx, vy, hp)) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, w->sparse && eid < w->sparse_cap && w->sparse[eid] >= 0
                          ? "already exists" : "capacity exceeded");
        return 2;
    }
    lua_pushinteger(L, (lua_Integer)ecs_slot(w, eid));
    return 1;
}

static int ldel(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    uint32_t eid = (uint32_t)luaL_checkinteger(L, 2);
    lua_pushboolean(L, ecs_del(*ud, eid) ? 1 : 0);
    return 1;
}

static int lhas(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    uint32_t eid = (uint32_t)luaL_checkinteger(L, 2);
    lua_pushboolean(L, ecs_has(*ud, eid) ? 1 : 0);
    return 1;
}

static int lget(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    ecs_world *w = *ud;
    uint32_t eid = (uint32_t)luaL_checkinteger(L, 2);
    int32_t slot = ecs_slot(w, eid);
    if (slot < 0) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushnumber(L, (lua_Number)w->px[slot]);
    lua_pushnumber(L, (lua_Number)w->py[slot]);
    lua_pushinteger(L, (lua_Integer)w->hp[slot]);
    lua_pushinteger(L, (lua_Integer)slot);
    return 4;
}

static int lset_velocity(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    ecs_world *w = *ud;
    uint32_t eid = (uint32_t)luaL_checkinteger(L, 2);
    int32_t slot = ecs_slot(w, eid);
    if (slot < 0) { lua_pushboolean(L, 0); return 1; }
    w->vx[slot] = (float)luaL_checknumber(L, 3);
    w->vy[slot] = (float)luaL_checknumber(L, 4);
    lua_pushboolean(L, 1);
    return 1;
}

static int ldamage_all(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    int32_t dmg = (int32_t)luaL_optinteger(L, 2, 1);
    ecs_damage_all(*ud, dmg);
    return 0;
}

static int lupdate(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    float dt = (float)luaL_optnumber(L, 2, 0.016);
    float bound = (float)luaL_optnumber(L, 3, 1000.0);
    ecs_update(*ud, dt, bound);
    return 0;
}

/*
 * bench：在 C 内部连续跑 ticks 帧并返回总耗时（纳秒）。
 *
 * 为什么不在 Lua 侧计时：
 *   1. 每帧一次的 Lua→C 调用开销会被计入，掩盖真实的 tick 成本
 *   2. skynet.time() 精度只有 10ms，远不够测亚毫秒帧
 *   这里用 CLOCK_MONOTONIC 纳秒计时，与 Lua 侧的 skynet.hpc() 同源。
 */
static int lbench(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    ecs_world *w = *ud;
    float dt = (float)luaL_optnumber(L, 2, 0.016);
    float bound = (float)luaL_optnumber(L, 3, 1000.0);
    uint32_t ticks = (uint32_t)luaL_optinteger(L, 4, 1);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (uint32_t i = 0; i < ticks; i++) {
        ecs_update(w, dt, bound);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double ns = (double)(t1.tv_sec - t0.tv_sec) * 1e9
              + (double)(t1.tv_nsec - t0.tv_nsec);
    lua_pushnumber(L, ns);
    return 1;
}

static int lcount(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    lua_pushinteger(L, (lua_Integer)(*ud)->n);
    return 1;
}

static int lcapacity(lua_State *L) {
    ecs_world **ud = (ecs_world **)luaL_checkudata(L, 1, MT_NAME);
    lua_pushinteger(L, (lua_Integer)(*ud)->cap);
    return 1;
}

static const luaL_Reg world_methods[] = {
    { "add",          ladd },
    { "del",          ldel },
    { "has",          lhas },
    { "get",          lget },
    { "set_velocity", lset_velocity },
    { "damage_all",   ldamage_all },
    { "update",       lupdate },
    { "bench",        lbench },
    { "count",        lcount },
    { "capacity",     lcapacity },
    { NULL, NULL },
};

static const luaL_Reg lib[] = {
    { "new", lnew },
    { NULL, NULL },
};

LUAMOD_API int luaopen_ecs_high(lua_State *L) {
    luaL_newmetatable(L, MT_NAME);

    luaL_newlib(L, world_methods);
    lua_setfield(L, -2, "__index");

    lua_pushcfunction(L, lgc);
    lua_setfield(L, -2, "__gc");

    lua_pop(L, 1);   /* metatable */

    luaL_newlib(L, lib);
    return 1;
}
