-- ============================================================================
-- 10_procedures_facts.sql
-- Fact loads (food_dw). Run after the dimension loads.
--
-- sp_load_fact_orders applies the business rules:
--   * net_amount = gross_amount - discount + delivery_fee (recomputed; the
--     source's own net_amount is not trusted);
--   * is_late = delivery_minutes > delivery_sla_minutes (pipeline_metadata);
--   * order_status mapped to DELIVERED / CANCELLED / REFUNDED;
--   * surrogate keys resolved, SCD2 dimensions point-in-time at order_datetime;
--   * invalid ratings and delivery times are nulled; structurally bad orders
--     (no customer, impossible timestamp, non-positive amount, unknown keys or
--     status) are rejected into stg_rejected_records.
-- Both procedures upsert on the fact grain, so re-loading a batch is idempotent.
-- ============================================================================

USE food_dw;

DROP PROCEDURE IF EXISTS sp_load_fact_orders;
DROP PROCEDURE IF EXISTS sp_load_fact_order_items;

DELIMITER $$

-- ----------------------------------------------------------------------------
-- fact_orders (grain: one row per order)
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_fact_orders(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_fact_orders';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_orders';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_sla_minutes INT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_order;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_orders);
    SET v_sla_minutes = food_control.fn_metadata_int('delivery_sla_minutes', 45);

    START TRANSACTION;

    -- 1. Cleanse and type the delta
    DROP TEMPORARY TABLE IF EXISTS tmp_order;
    CREATE TEMPORARY TABLE tmp_order AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.order_id))            AS order_id,
           UPPER(food_staging.fn_clean_text(s.customer_id))         AS customer_id,
           UPPER(food_staging.fn_clean_text(s.restaurant_id))       AS restaurant_id,
           UPPER(food_staging.fn_clean_text(s.delivery_partner_id)) AS delivery_partner_id,
           UPPER(food_staging.fn_clean_text(s.payment_method_id))   AS payment_method_id,
           food_staging.fn_to_datetime(s.order_datetime)            AS order_datetime,
           food_staging.fn_to_decimal(s.gross_amount)               AS gross_amount,
           COALESCE(food_staging.fn_to_decimal(s.discount), 0)      AS discount,
           COALESCE(food_staging.fn_to_decimal(s.delivery_fee), 0)  AS delivery_fee,
           food_staging.fn_to_int(s.delivery_minutes)               AS delivery_minutes,
           food_staging.fn_to_decimal(s.rating)                     AS rating,
           CASE UPPER(food_staging.fn_clean_text(s.order_status))
               WHEN 'DELIVERED' THEN 'DELIVERED'
               WHEN 'CANCELLED' THEN 'CANCELLED'
               WHEN 'CANCELED'  THEN 'CANCELLED'
               WHEN 'REFUNDED'  THEN 'REFUNDED'
           END                                                      AS order_status,
           CAST(NULL AS SIGNED)    AS date_key,
           CAST(NULL AS SIGNED)    AS customer_key,
           CAST(NULL AS SIGNED)    AS restaurant_key,
           CAST(NULL AS SIGNED)    AS delivery_partner_key,
           CAST(NULL AS SIGNED)    AS payment_method_key,
           CAST(NULL AS CHAR(255)) AS reject_reason
    FROM food_staging.stg_orders s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    -- 2. Resolve surrogate keys (SCD2 dimensions: version valid at order time)
    UPDATE tmp_order t
    LEFT JOIN dim_date d             ON d.full_date = DATE(t.order_datetime)
    LEFT JOIN dim_delivery_partner p ON p.partner_id = t.delivery_partner_id
    LEFT JOIN dim_payment_method m   ON m.payment_method_id = t.payment_method_id
    SET t.date_key = d.date_key,
        t.delivery_partner_key = p.delivery_partner_key,
        t.payment_method_key = m.payment_method_key;

    UPDATE tmp_order t
    JOIN dim_customer c ON c.customer_id = t.customer_id
                       AND t.order_datetime >= c.valid_from AND t.order_datetime < c.valid_to
    SET t.customer_key = c.customer_key;

    UPDATE tmp_order t
    JOIN dim_restaurant r ON r.restaurant_id = t.restaurant_id
                         AND t.order_datetime >= r.valid_from AND t.order_datetime < r.valid_to
    SET t.restaurant_key = r.restaurant_key;

    -- 3. Reject what cannot be loaded; null out values that are merely invalid
    UPDATE tmp_order
    SET reject_reason = CASE
            WHEN order_id IS NULL THEN 'missing order_id'
            WHEN customer_id IS NULL THEN 'missing customer_id'
            WHEN order_datetime IS NULL THEN 'invalid order_datetime'
            WHEN date_key IS NULL THEN 'order_datetime outside dim_date calendar'
            WHEN gross_amount IS NULL OR gross_amount <= 0 THEN 'gross_amount must be positive'
            WHEN discount < 0 OR discount > gross_amount THEN 'invalid discount'
            WHEN delivery_fee < 0 THEN 'invalid delivery_fee'
            WHEN order_status IS NULL THEN 'unknown order_status'
            WHEN customer_key IS NULL THEN 'unknown customer_id'
            WHEN restaurant_key IS NULL THEN 'unknown restaurant_id'
            WHEN delivery_partner_key IS NULL THEN 'unknown delivery_partner_id'
            WHEN payment_method_key IS NULL THEN 'unknown payment_method_id'
        END,
        rating = IF(rating BETWEEN 1 AND 5, rating, NULL),
        delivery_minutes = IF(order_status = 'CANCELLED' OR delivery_minutes NOT BETWEEN 1 AND 300,
                              NULL, delivery_minutes);
    SET v_read = (SELECT COUNT(*) FROM tmp_order);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_order);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.order_id, t.reject_reason, c_job_name,
           JSON_OBJECT('order_id', s.order_id, 'customer_id', s.customer_id, 'restaurant_id', s.restaurant_id,
                       'delivery_partner_id', s.delivery_partner_id, 'payment_method_id', s.payment_method_id,
                       'order_datetime', s.order_datetime, 'gross_amount', s.gross_amount,
                       'discount', s.discount, 'delivery_fee', s.delivery_fee, 'net_amount', s.net_amount,
                       'delivery_minutes', s.delivery_minutes, 'rating', s.rating, 'order_status', s.order_status)
    FROM tmp_order t
    JOIN food_staging.stg_orders s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    -- 4. Upsert the latest valid row per order (duplicates collapse to one)
    SELECT COALESCE(SUM(f.order_key IS NULL), 0), COALESCE(SUM(f.order_key IS NOT NULL), 0)
    INTO v_inserted, v_updated
    FROM (SELECT t.order_id, ROW_NUMBER() OVER (PARTITION BY t.order_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_order t WHERE t.reject_reason IS NULL) AS x
    LEFT JOIN fact_orders f ON f.order_id = x.order_id
    WHERE x.rn = 1;

    INSERT INTO fact_orders
        (order_id, date_key, customer_key, restaurant_key, delivery_partner_key, payment_method_key,
         order_datetime, gross_amount, discount, delivery_fee, net_amount, delivery_minutes, is_late,
         rating, order_status, batch_id)
    SELECT src.order_id, src.date_key, src.customer_key, src.restaurant_key, src.delivery_partner_key,
           src.payment_method_key, src.order_datetime, src.gross_amount, src.discount, src.delivery_fee,
           src.gross_amount - src.discount + src.delivery_fee,
           src.delivery_minutes,
           COALESCE(src.delivery_minutes > v_sla_minutes, 0),
           src.rating, src.order_status, src.batch_id
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.order_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_order t WHERE t.reject_reason IS NULL) AS src
    WHERE src.rn = 1
    ON DUPLICATE KEY UPDATE
        date_key             = src.date_key,
        customer_key         = src.customer_key,
        restaurant_key       = src.restaurant_key,
        delivery_partner_key = src.delivery_partner_key,
        payment_method_key   = src.payment_method_key,
        order_datetime       = src.order_datetime,
        gross_amount         = src.gross_amount,
        discount             = src.discount,
        delivery_fee         = src.delivery_fee,
        net_amount           = src.gross_amount - src.discount + src.delivery_fee,
        delivery_minutes     = src.delivery_minutes,
        is_late              = COALESCE(src.delivery_minutes > v_sla_minutes, 0),
        rating               = src.rating,
        order_status         = src.order_status,
        batch_id             = src.batch_id;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_order;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

-- ----------------------------------------------------------------------------
-- fact_order_items (grain: one row per menu item per order)
-- Items of orders that sp_load_fact_orders rejected are rejected here too.
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_fact_order_items(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_fact_order_items';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_order_items';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_order_item;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_order_items);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_order_item;
    CREATE TEMPORARY TABLE tmp_order_item AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.order_id)) AS order_id,
           UPPER(food_staging.fn_clean_text(s.item_id))  AS item_id,
           food_staging.fn_to_int(s.quantity)            AS quantity,
           food_staging.fn_to_decimal(s.unit_price)      AS unit_price,
           CAST(NULL AS SIGNED)    AS order_key,
           CAST(NULL AS SIGNED)    AS menu_item_key,
           CAST(NULL AS CHAR(255)) AS reject_reason
    FROM food_staging.stg_order_items s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_order_item t
    LEFT JOIN fact_orders f   ON f.order_id = t.order_id
    LEFT JOIN dim_menu_item m ON m.item_id = t.item_id
    SET t.order_key = f.order_key,
        t.menu_item_key = m.menu_item_key;

    UPDATE tmp_order_item
    SET reject_reason = CASE
        WHEN order_id IS NULL THEN 'missing order_id'
        WHEN item_id IS NULL THEN 'missing item_id'
        WHEN quantity IS NULL OR quantity <= 0 THEN 'quantity must be a positive whole number'
        WHEN unit_price IS NULL OR unit_price < 0 THEN 'invalid unit_price'
        WHEN order_key IS NULL THEN 'order not loaded (missing or rejected in stg_orders)'
        WHEN menu_item_key IS NULL THEN 'unknown item_id'
    END;
    SET v_read = (SELECT COUNT(*) FROM tmp_order_item);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_order_item);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, CONCAT_WS('/', t.order_id, t.item_id), t.reject_reason, c_job_name,
           JSON_OBJECT('order_id', s.order_id, 'item_id', s.item_id, 'quantity', s.quantity,
                       'unit_price', s.unit_price)
    FROM tmp_order_item t
    JOIN food_staging.stg_order_items s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    SELECT COALESCE(SUM(f.order_item_key IS NULL), 0), COALESCE(SUM(f.order_item_key IS NOT NULL), 0)
    INTO v_inserted, v_updated
    FROM (SELECT t.order_key, t.menu_item_key,
                 ROW_NUMBER() OVER (PARTITION BY t.order_key, t.menu_item_key ORDER BY t.stg_id DESC) AS rn
          FROM tmp_order_item t WHERE t.reject_reason IS NULL) AS x
    LEFT JOIN fact_order_items f ON f.order_key = x.order_key AND f.menu_item_key = x.menu_item_key
    WHERE x.rn = 1;

    INSERT INTO fact_order_items (order_key, menu_item_key, quantity, unit_price, line_total, batch_id)
    SELECT src.order_key, src.menu_item_key, src.quantity, src.unit_price,
           src.quantity * src.unit_price, src.batch_id
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.order_key, t.menu_item_key ORDER BY t.stg_id DESC) AS rn
          FROM tmp_order_item t WHERE t.reject_reason IS NULL) AS src
    WHERE src.rn = 1
    ON DUPLICATE KEY UPDATE
        quantity   = src.quantity,
        unit_price = src.unit_price,
        line_total = src.quantity * src.unit_price,
        batch_id   = src.batch_id;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_order_item;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

DELIMITER ;
