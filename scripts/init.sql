-- ─────────────────────────────────────────────────────────────
-- Schéma initial — Barcode Project (MySQL 8.4)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS barcodes (
    id           CHAR(36)     NOT NULL DEFAULT (UUID()),
    barcode      VARCHAR(20)  NOT NULL,
    format       VARCHAR(20)  NOT NULL DEFAULT 'EAN13',
    s3_key       TEXT,
    s3_url       TEXT,
    created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at DATETIME,
    PRIMARY KEY (id),
    INDEX idx_barcode (barcode)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Idempotence : empêche le double traitement des messages
CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   CHAR(36)     NOT NULL,
    barcode      VARCHAR(20)  NOT NULL,
    processed_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (message_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- DLQ applicative : messages en échec après max retries
CREATE TABLE IF NOT EXISTS dead_letter_messages (
    id           CHAR(36)     NOT NULL DEFAULT (UUID()),
    message_id   CHAR(36)     NOT NULL,
    barcode      VARCHAR(20),
    payload      JSON         NOT NULL,
    error        TEXT         NOT NULL,
    attempts     INT          NOT NULL DEFAULT 0,
    failed_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;