-- ============================================================================
-- 11_procedures_orchestration.sql
-- sp_run_warehouse_load: runs every load procedure in dependency order
--                        (dimensions before facts, orders before order items).
-- sp_reset_warehouse:    empties the warehouse and rewinds all watermarks, so the
--                        next load rebuilds everything (incl. SCD2 history) from
--                        the staging history. Used by run_pipeline.py --full-refresh.
-- ============================================================================

USE food_dw;

DROP PROCEDURE IF EXISTS sp_run_warehouse_load;
DROP PROCEDURE IF EXISTS sp_reset_warehouse;

DELIMITER $$

CREATE PROCEDURE sp_run_warehouse_load(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_run_warehouse_load';
    DECLARE v_job_id BIGINT;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    -- Each child procedure logs and rolls back its own failure; this handler
    -- marks the overall run as failed and re-raises to the caller.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);

    CALL sp_load_dim_payment_method(p_batch_id);
    CALL sp_load_dim_delivery_partner(p_batch_id);
    CALL sp_load_dim_restaurant(p_batch_id);
    CALL sp_load_dim_menu_item(p_batch_id);
    CALL sp_load_dim_customer(p_batch_id);
    CALL sp_load_fact_orders(p_batch_id);
    CALL sp_load_fact_order_items(p_batch_id);

    CALL food_control.sp_job_finish(v_job_id, 0, 0, 0, 0);
END$$

CREATE PROCEDURE sp_reset_warehouse(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_reset_warehouse';
    DECLARE v_job_id BIGINT;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);

    START TRANSACTION;
    -- DELETE rather than TRUNCATE: TRUNCATE is not allowed on tables referenced by foreign keys
    DELETE FROM fact_order_items;
    DELETE FROM fact_orders;
    DELETE FROM dim_customer;
    DELETE FROM dim_restaurant;
    DELETE FROM dim_menu_item;
    DELETE FROM dim_delivery_partner;
    DELETE FROM dim_payment_method;
    DELETE FROM food_staging.stg_rejected_records;
    UPDATE food_control.pipeline_metadata SET metadata_value = '0' WHERE metadata_key LIKE 'watermark.%';
    COMMIT;

    CALL food_control.sp_job_finish(v_job_id, 0, 0, 0, 0);
END$$

DELIMITER ;
