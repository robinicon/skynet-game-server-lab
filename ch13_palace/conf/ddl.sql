-- ch13_palace 最小表集（阶段 2）
-- 目标：6 张表承载抽象数据；实体字段按分区存 payload，只有 index 字段单独成列。
-- MySQL 驱动 init 时会读取本文件并逐条执行（幂等，CREATE TABLE IF NOT EXISTS）。

CREATE TABLE IF NOT EXISTS account (
    uid         BIGINT       NOT NULL AUTO_INCREMENT,
    name        VARCHAR(128) NOT NULL,
    salt        VARCHAR(64)  NOT NULL,
    pwd_hash    VARCHAR(64)  NOT NULL,
    sdk_id      INT          NOT NULL DEFAULT 0,
    status      INT          NOT NULL DEFAULT 0,
    PRIMARY KEY (uid),
    UNIQUE KEY uk_account_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS entity (
    uid         BIGINT       NOT NULL,
    etype       VARCHAR(32)  NOT NULL,
    owner       BIGINT       NOT NULL DEFAULT 0,
    account     VARCHAR(128) NOT NULL DEFAULT '',
    rev         BIGINT       NOT NULL DEFAULT 0,
    updated_at  BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (uid),
    KEY idx_entity_account (account)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS entity_partition (
    uid         BIGINT       NOT NULL,
    `partition` VARCHAR(32)  NOT NULL,
    rev         BIGINT       NOT NULL DEFAULT 0,
    payload     TEXT         NOT NULL,
    crc         BIGINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (uid, `partition`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS entity_field (
    uid         BIGINT       NOT NULL,
    fid         INT          NOT NULL,
    value       VARCHAR(512) NOT NULL,
    PRIMARY KEY (uid, fid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS event_log (
    seq         BIGINT       NOT NULL AUTO_INCREMENT,
    uid         BIGINT       NOT NULL DEFAULT 0,
    aid         INT          NOT NULL DEFAULT 0,
    ts          BIGINT       NOT NULL DEFAULT 0,
    actor       VARCHAR(128) NOT NULL DEFAULT '',
    PRIMARY KEY (seq),
    KEY idx_event_uid (uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS leaderboard_projection (
    rank_key    VARCHAR(128) NOT NULL,
    uid         BIGINT       NOT NULL,
    score       DOUBLE       NOT NULL DEFAULT 0,
    PRIMARY KEY (rank_key, uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
