-- roles 表 · v2（创角竖切所需，V07 交付物）
--
-- 三条设计取舍：
-- 1. `name` 必须唯一且区分大小写不敏感（utf8mb4_0900_ai_ci 本身不区分），
--    靠唯一索引兜住并发创角，不靠"先查再插"——那是竞态（同 ch7 的丢失更新）。
-- 2. 业务字段全部 NOT NULL + DEFAULT，避免部分更新时把未提供的列写成 NULL
--    （ch7_db 的 D3.2 就是这么丢的 gold）。
-- 3. `version` 留给乐观锁 / 增量比对，不与 `updated_at` 混用。

CREATE TABLE IF NOT EXISTS `roles` (
  `uid`         INT           NOT NULL,
  `name`        VARCHAR(32)   NOT NULL,
  `level`       SMALLINT      NOT NULL DEFAULT 1,
  `profession`  TINYINT       NOT NULL DEFAULT 0,
  `gender`      TINYINT       NOT NULL DEFAULT 0,
  `hp`          INT           NOT NULL DEFAULT 0,
  `gold`        INT           NOT NULL DEFAULT 0,
  `version`     INT           NOT NULL DEFAULT 0,
  `created_at`  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`uid`),
  UNIQUE KEY `uk_roles_name` (`name`),
  KEY `idx_roles_level` (`level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 从 v1 迁移（幂等）：MySQL 8 不支持 ADD COLUMN IF NOT EXISTS，
-- 所以迁移脚本要先用 information_schema 判断，这里给出待执行语句供人工/DBA 复核。
--
-- ALTER TABLE `roles`
--   ADD COLUMN `name`       VARCHAR(32) NOT NULL DEFAULT '' AFTER `uid`,
--   ADD COLUMN `level`      SMALLINT    NOT NULL DEFAULT 1,
--   ADD COLUMN `profession` TINYINT     NOT NULL DEFAULT 0,
--   ADD COLUMN `gender`     TINYINT     NOT NULL DEFAULT 0,
--   ADD COLUMN `created_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
--   ADD UNIQUE KEY `uk_roles_name` (`name`),
--   ADD KEY        `idx_roles_level` (`level`);
--
-- 注意：存量行 `name` 会是空串，唯一索引在第二行就撞。
-- 必须先 `UPDATE roles SET name = CONCAT('role_', uid) WHERE name = ''`，再加索引。
