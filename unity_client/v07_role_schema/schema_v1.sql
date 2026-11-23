-- roles 表 · v1（现状，对应台账 C-28）
-- 事实：ch7_db 里只有这四列，创角所需的 name / level / profession / gender 都没有。
-- 保留这份文件是为了让 `check_schema.py --diff` 能算出"要补哪几列"。

CREATE TABLE IF NOT EXISTS `roles` (
  `uid`        INT NOT NULL,
  `hp`         INT NOT NULL DEFAULT 0,
  `gold`       INT NOT NULL DEFAULT 0,
  `version`    INT NOT NULL DEFAULT 0,
  `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
