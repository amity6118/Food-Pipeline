-- ============================================================================
-- 08_procedures_control.sql
-- Shared helpers in food_control used by every warehouse load procedure:
-- job logging (start / finish / fail), watermarks and pipeline settings.
--
-- Callers must run with autocommit on (the Python runner does): sp_job_start
-- then commits immediately, and sp_job_fail runs after the caller's ROLLBACK,
-- so the audit trail survives even when the load itself is rolled back.
-- ============================================================================

USE food_control;

DROP PROCEDURE IF EXISTS sp_job_start;
DROP PROCEDURE IF EXISTS sp_job_finish;
DROP PROCEDURE IF EXISTS sp_job_fail;
DROP PROCEDURE IF EXISTS sp_set_watermark;
DROP FUNCTION IF EXISTS fn_metadata_int;
DROP FUNCTION IF EXISTS fn_get_watermark;
DROP FUNCTION IF EXISTS fn_batch_date;

DELIMITER $$

-- Opens a RUNNING entry in etl_job_log and returns its id.
CREATE PROCEDURE sp_job_start(IN p_job_name VARCHAR(100), IN p_batch_id VARCHAR(64), OUT p_job_id BIGINT)
BEGIN
    INSERT INTO etl_job_log (job_name, batch_id, status, start_time)
    VALUES (p_job_name, p_batch_id, 'RUNNING', NOW());
    SET p_job_id = LAST_INSERT_ID();
END$$

-- Marks a job SUCCESS with its row counts.
CREATE PROCEDURE sp_job_finish(IN p_job_id BIGINT, IN p_rows_read INT, IN p_rows_inserted INT,
                               IN p_rows_updated INT, IN p_rows_rejected INT)
BEGIN
    UPDATE etl_job_log
    SET status = 'SUCCESS', end_time = NOW(), rows_read = p_rows_read, rows_inserted = p_rows_inserted,
        rows_updated = p_rows_updated, rows_rejected = p_rows_rejected
    WHERE job_id = p_job_id;
END$$

-- Marks a job FAILED and records the error in etl_error_log.
CREATE PROCEDURE sp_job_fail(IN p_job_id BIGINT, IN p_batch_id VARCHAR(64), IN p_step_name VARCHAR(100),
                             IN p_error_code VARCHAR(20), IN p_error_message TEXT)
BEGIN
    UPDATE etl_job_log
    SET status = 'FAILED', end_time = NOW(), error_message = p_error_message
    WHERE job_id = p_job_id;

    INSERT INTO etl_error_log (job_id, batch_id, step_name, error_code, error_message)
    VALUES (p_job_id, p_batch_id, p_step_name, p_error_code, COALESCE(p_error_message, 'unknown error'));
END$$

-- Integer setting from pipeline_metadata, or p_default when absent.
CREATE FUNCTION fn_metadata_int(p_key VARCHAR(100), p_default BIGINT)
RETURNS BIGINT
READS SQL DATA
BEGIN
    RETURN COALESCE((SELECT CAST(metadata_value AS UNSIGNED) FROM pipeline_metadata WHERE metadata_key = p_key),
                    p_default);
END$$

-- Last staging stg_id processed for a staging table (0 = nothing processed yet).
CREATE FUNCTION fn_get_watermark(p_staging_table VARCHAR(64))
RETURNS BIGINT
READS SQL DATA
BEGIN
    RETURN fn_metadata_int(CONCAT('watermark.', p_staging_table), 0);
END$$

-- Advances a watermark; called inside the load's transaction so data and
-- watermark commit (or roll back) together.
CREATE PROCEDURE sp_set_watermark(IN p_staging_table VARCHAR(64), IN p_stg_id BIGINT)
BEGIN
    INSERT INTO pipeline_metadata (metadata_key, metadata_value, description)
    VALUES (CONCAT('watermark.', p_staging_table), p_stg_id, CONCAT('Last stg_id processed from ', p_staging_table))
    AS new
    ON DUPLICATE KEY UPDATE metadata_value = new.metadata_value;
END$$

-- Business date of a batch id: 'B20261012' -> 2026-10-12.
CREATE FUNCTION fn_batch_date(p_batch_id VARCHAR(64))
RETURNS DATE
DETERMINISTIC NO SQL
BEGIN
    RETURN MAKEDATE(SUBSTRING(p_batch_id, 2, 4), 1)
           + INTERVAL (SUBSTRING(p_batch_id, 6, 2) - 1) MONTH
           + INTERVAL (SUBSTRING(p_batch_id, 8, 2) - 1) DAY;
END$$

DELIMITER ;
