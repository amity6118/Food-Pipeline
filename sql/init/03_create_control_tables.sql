-- ============================================================================
-- 03_create_control_tables.sql
-- Description: Control database containing audit logs, error logs, DQ rules, and watermarks
-- ============================================================================

USE food_control;

-- ----------------------------------------------------------------------------
-- 1. ETL Job Execution Log
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS etl_job_log;
CREATE TABLE etl_job_log (
    job_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    job_name VARCHAR(100) NOT NULL,
    batch_id VARCHAR(64) NOT NULL,
    status VARCHAR(20) NOT NULL COMMENT 'RUNNING, SUCCESS, FAILED',
    start_time DATETIME NOT NULL,
    end_time DATETIME NULL,
    rows_read INT DEFAULT 0,
    rows_inserted INT DEFAULT 0,
    rows_updated INT DEFAULT 0,
    rows_rejected INT DEFAULT 0,
    error_message TEXT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_job_batch (batch_id),
    INDEX idx_job_name_status (job_name, status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 2. ETL Detailed Error Log
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS etl_error_log;
CREATE TABLE etl_error_log (
    error_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id VARCHAR(64) NOT NULL,
    step_name VARCHAR(100) NOT NULL,
    error_code VARCHAR(50) NULL,
    error_message TEXT NOT NULL,
    error_stack TEXT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_err_batch (batch_id),
    INDEX idx_err_step (step_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 3. Data Quality Rules (Table-Driven DQ Engine)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dq_rules;
CREATE TABLE dq_rules (
    rule_id INT AUTO_INCREMENT PRIMARY KEY,
    rule_name VARCHAR(100) NOT NULL UNIQUE,
    target_database VARCHAR(100) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    column_name VARCHAR(100) NULL,
    rule_type VARCHAR(50) NOT NULL COMMENT 'NULL_CHECK, RANGE_CHECK, REFERENTIAL_CHECK, FRESHNESS_CHECK, FORMAT_CHECK',
    condition_sql TEXT NOT NULL COMMENT 'SELECT COUNT(*) expression yielding violation row count',
    severity VARCHAR(20) NOT NULL DEFAULT 'FAIL' COMMENT 'WARN or FAIL',
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    description VARCHAR(255) NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 4. Data Quality Execution Results
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dq_results;
CREATE TABLE dq_results (
    result_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id VARCHAR(64) NOT NULL,
    rule_id INT NOT NULL,
    rule_name VARCHAR(100) NOT NULL,
    target_table VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    passed TINYINT(1) NOT NULL,
    failed_count INT NOT NULL DEFAULT 0,
    sample_failures JSON NULL,
    executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_dqr_batch (batch_id),
    INDEX idx_dqr_rule (rule_id),
    INDEX idx_dqr_passed (passed)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 5. Pipeline Metadata & High Watermarks
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS pipeline_metadata;
CREATE TABLE pipeline_metadata (
    metadata_key VARCHAR(100) PRIMARY KEY,
    metadata_value VARCHAR(255) NOT NULL,
    description VARCHAR(255) NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
