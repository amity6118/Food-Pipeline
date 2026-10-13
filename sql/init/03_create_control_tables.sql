-- ============================================================================
-- 03_create_control_tables.sql
-- Control database (food_control): job audit trail, error log, table-driven
-- data quality rules and results, and pipeline metadata / watermarks.
-- ============================================================================

USE food_control;

-- ----------------------------------------------------------------------------
-- One row per pipeline step or stored-procedure run
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS etl_job_log (
    job_id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    job_name         VARCHAR(100) NOT NULL COMMENT 'Pipeline step or procedure name',
    batch_id         VARCHAR(64)  NOT NULL,
    status           ENUM('RUNNING', 'SUCCESS', 'FAILED') NOT NULL,
    start_time       DATETIME     NOT NULL,
    end_time         DATETIME     NULL,
    duration_seconds INT GENERATED ALWAYS AS (TIMESTAMPDIFF(SECOND, start_time, end_time)) VIRTUAL,
    rows_read        INT          NOT NULL DEFAULT 0,
    rows_inserted    INT          NOT NULL DEFAULT 0,
    rows_updated     INT          NOT NULL DEFAULT 0,
    rows_rejected    INT          NOT NULL DEFAULT 0,
    error_message    TEXT         NULL,
    INDEX idx_job_batch (batch_id),
    INDEX idx_job_name_start (job_name, start_time),
    INDEX idx_job_status (status)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Detailed errors (SQL error codes, Python tracebacks), linked to the job
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS etl_error_log (
    error_id        BIGINT AUTO_INCREMENT PRIMARY KEY,
    job_id          BIGINT       NULL,
    batch_id        VARCHAR(64)  NOT NULL,
    step_name       VARCHAR(100) NOT NULL,
    error_code      VARCHAR(20)  NULL COMMENT 'MySQL errno / SQLSTATE, or Python exception type',
    error_message   TEXT         NOT NULL,
    error_detail    TEXT         NULL COMMENT 'Stack trace or failing statement',
    created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_error_job FOREIGN KEY (job_id) REFERENCES etl_job_log (job_id) ON DELETE SET NULL,
    INDEX idx_error_batch (batch_id),
    INDEX idx_error_step (step_name)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Data quality rules. Each rule is a SELECT that returns one row per violation;
-- the DQ engine counts the rows and stores a few as samples. Rules may reference
-- the current batch with the :batch_id bind parameter.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_rules (
    rule_id          INT AUTO_INCREMENT PRIMARY KEY,
    rule_name        VARCHAR(100) NOT NULL,
    stage            ENUM('STAGING', 'WAREHOUSE') NOT NULL
                     COMMENT 'STAGING rules run before the procedures, WAREHOUSE rules after',
    rule_type        ENUM('NULL_CHECK', 'RANGE_CHECK', 'FORMAT_CHECK', 'UNIQUENESS_CHECK',
                          'REFERENTIAL_CHECK', 'FRESHNESS_CHECK', 'VOLUME_CHECK',
                          'RECONCILIATION_CHECK') NOT NULL,
    target_table     VARCHAR(130) NOT NULL COMMENT 'database.table inspected by the rule',
    target_column    VARCHAR(64)  NULL,
    violation_query  TEXT         NOT NULL COMMENT 'SELECT returning one row per violation',
    severity         ENUM('WARN', 'FAIL') NOT NULL DEFAULT 'FAIL' COMMENT 'FAIL stops the pipeline',
    max_violations   INT          NOT NULL DEFAULT 0 COMMENT 'Violations tolerated before the rule is breached',
    is_active        TINYINT(1)   NOT NULL DEFAULT 1,
    description      VARCHAR(255) NULL,
    created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dq_rule_name (rule_name),
    INDEX idx_dq_rules_stage (stage, is_active)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- One row per rule per batch
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dq_results (
    result_id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id          VARCHAR(64)  NOT NULL,
    rule_id           INT          NOT NULL,
    rule_name         VARCHAR(100) NOT NULL,
    stage             ENUM('STAGING', 'WAREHOUSE') NOT NULL,
    severity          ENUM('WARN', 'FAIL') NOT NULL,
    violation_count   INT          NOT NULL,
    outcome           ENUM('PASS', 'WARN', 'FAIL') NOT NULL,
    sample_violations JSON         NULL COMMENT 'Up to five example violating rows',
    executed_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_dq_results_rule FOREIGN KEY (rule_id) REFERENCES dq_rules (rule_id),
    INDEX idx_dq_results_batch (batch_id),
    INDEX idx_dq_results_outcome (outcome)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Key/value pipeline state, including per-table incremental watermarks
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pipeline_metadata (
    metadata_key    VARCHAR(100) PRIMARY KEY,
    metadata_value  VARCHAR(255) NOT NULL,
    description     VARCHAR(255) NULL,
    updated_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;
