/*
 * ecs_high.h — 高频 ECS（C 实现）
 *
 * 定位（design.md Phase 3）：
 *   高频路径（战斗 tick、AOI 实时更新）用 C：结构体 + 数组存储，零 GC 压力。
 *   低频路径（背包、任务等 CRUD）用 Lua：见 shared/ecs_low.lua。
 *
 * 数据结构：sparse-set + SoA（Structure of Arrays）
 *   sparse[eid]     → slot（int32，-1 表示不存在），O(1) 定位
 *   dense 数组       → 按 slot 连续存放各 component 字段
 *
 * 为什么用 SoA 而不是 AoS：
 *   - 遍历单个 component（如只更新 position）时 cache 命中率最高
 *   - 打包成数组后可整段预取，CPU 能流水化
 *   - 与 Lua 侧交互时只转换需要的字段
 *
 * 删除用 swap-remove：把末尾元素移到删除位置，O(1) 且保持数组紧凑。
 */

#ifndef ECS_HIGH_H
#define ECS_HIGH_H

#include <stdint.h>

typedef struct {
    uint32_t cap;        /* dense 容量 */
    uint32_t n;          /* 活跃 entity 数 */
    uint32_t sparse_cap; /* sparse 容量 */
    int32_t *sparse;     /* eid → slot，-1 = 不存在 */
    uint32_t *eid;       /* slot → eid */
    float    *px, *py;   /* position */
    float    *vx, *vy;   /* velocity */
    int32_t  *hp;        /* health */
    int32_t  *maxhp;
} ecs_world;

/* 生命周期 */
ecs_world *ecs_world_new(uint32_t cap);
void       ecs_world_free(ecs_world *w);

/* 实体操作 */
int   ecs_add(ecs_world *w, uint32_t eid,
              float px, float py, float vx, float vy, int32_t hp);
int   ecs_del(ecs_world *w, uint32_t eid);
int   ecs_has(ecs_world *w, uint32_t eid);
int32_t ecs_slot(ecs_world *w, uint32_t eid);

/* 系统：一次战斗 tick = 移动 + 边界反弹 + 血量回复 */
void ecs_update(ecs_world *w, float dt, float bound);
void ecs_damage_all(ecs_world *w, int32_t dmg);

#endif /* ECS_HIGH_H */
