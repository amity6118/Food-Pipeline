-- ============================================================================
-- 09_procedures_dimensions.sql
-- Dimension loads (food_dw). Each procedure:
--   1. reads only the staging delta: stg_id > its watermark (incremental load),
--      skipping batches held back by a failed staging DQ check;
--   2. cleanses values with the food_staging.fn_* functions;
--   3. rejects rows missing required fields into stg_rejected_records
--      (replacing earlier rejections of the same batches, so re-runs don't duplicate them);
--   4. upserts (SCD1) or versions (SCD2) the dimension, keeping the latest row
--      per natural key when a batch contains duplicates;
--   5. advances its watermark in the same transaction and logs to etl_job_log.
-- Any SQL error rolls the load back, is logged as FAILED, and is re-raised.
-- ============================================================================

USE food_dw;

DROP PROCEDURE IF EXISTS sp_load_dim_payment_method;
DROP PROCEDURE IF EXISTS sp_load_dim_delivery_partner;
DROP PROCEDURE IF EXISTS sp_load_dim_menu_item;
DROP PROCEDURE IF EXISTS sp_load_dim_restaurant;
DROP PROCEDURE IF EXISTS sp_load_dim_customer;

DELIMITER $$

-- ----------------------------------------------------------------------------
-- dim_payment_method (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_dim_payment_method(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_dim_payment_method';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_payment_methods';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_payment_method;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_payment_methods);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_payment_method;
    CREATE TEMPORARY TABLE tmp_payment_method AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.payment_method_id)) AS payment_method_id,
           food_staging.fn_clean_text(s.method_name)               AS method_name,
           UPPER(food_staging.fn_clean_text(s.method_category))   AS method_category,
           CAST(NULL AS CHAR(255))                                 AS reject_reason
    FROM food_staging.stg_payment_methods s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_payment_method
    SET reject_reason = CASE
        WHEN payment_method_id IS NULL THEN 'missing payment_method_id'
        WHEN method_name IS NULL THEN 'missing method_name'
        WHEN COALESCE(method_category, '') NOT IN ('UPI', 'CARD', 'NETBANKING', 'COD', 'WALLET')
            THEN 'unknown method_category'
    END;
    SET v_read = (SELECT COUNT(*) FROM tmp_payment_method);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_payment_method);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.payment_method_id, t.reject_reason, c_job_name,
           JSON_OBJECT('payment_method_id', s.payment_method_id, 'method_name', s.method_name,
                       'method_category', s.method_category)
    FROM tmp_payment_method t
    JOIN food_staging.stg_payment_methods s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    -- Count new vs changed keys before the upsert
    SELECT COALESCE(SUM(d.payment_method_key IS NULL), 0),
           COALESCE(SUM(d.payment_method_key IS NOT NULL
                        AND NOT (d.method_name <=> x.method_name AND d.method_category <=> x.method_category)), 0)
    INTO v_inserted, v_updated
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.payment_method_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_payment_method t WHERE t.reject_reason IS NULL) AS x
    LEFT JOIN dim_payment_method d ON d.payment_method_id = x.payment_method_id
    WHERE x.rn = 1;

    INSERT INTO dim_payment_method (payment_method_id, method_name, method_category, batch_id)
    SELECT src.payment_method_id, src.method_name, src.method_category, src.batch_id
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.payment_method_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_payment_method t WHERE t.reject_reason IS NULL) AS src
    WHERE src.rn = 1
    ON DUPLICATE KEY UPDATE
        -- batch_id records the batch that last changed the row, so compare before overwriting
        batch_id        = IF(dim_payment_method.method_name <=> src.method_name AND dim_payment_method.method_category <=> src.method_category,
                             dim_payment_method.batch_id, src.batch_id),
        method_name     = src.method_name,
        method_category = src.method_category;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_payment_method;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

-- ----------------------------------------------------------------------------
-- dim_delivery_partner (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_dim_delivery_partner(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_dim_delivery_partner';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_delivery_partners';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_delivery_partner;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_delivery_partners);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_delivery_partner;
    CREATE TEMPORARY TABLE tmp_delivery_partner AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.partner_id)) AS partner_id,
           food_staging.fn_clean_text(s.partner_name)      AS partner_name,
           food_staging.fn_clean_phone(s.phone)             AS phone,
           CASE UPPER(food_staging.fn_clean_text(s.vehicle_type))
               WHEN 'BIKE' THEN 'Bike' WHEN 'SCOOTER' THEN 'Scooter'
               WHEN 'EV SCOOTER' THEN 'EV Scooter' WHEN 'BICYCLE' THEN 'Bicycle'
               ELSE food_staging.fn_clean_text(s.vehicle_type)
           END                                              AS vehicle_type,
           food_staging.fn_clean_text(s.city)               AS city,
           IF(food_staging.fn_to_decimal(s.rating) BETWEEN 1 AND 5,
              food_staging.fn_to_decimal(s.rating), NULL)   AS rating,
           UPPER(food_staging.fn_clean_text(s.status))      AS status,
           CAST(NULL AS CHAR(255))                          AS reject_reason
    FROM food_staging.stg_delivery_partners s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_delivery_partner
    SET reject_reason = CASE
        WHEN partner_id IS NULL THEN 'missing partner_id'
        WHEN partner_name IS NULL THEN 'missing partner_name'
        WHEN city IS NULL THEN 'missing city'
        WHEN vehicle_type IS NULL THEN 'missing vehicle_type'
        WHEN COALESCE(status, '') NOT IN ('ACTIVE', 'ON_LEAVE', 'INACTIVE') THEN 'unknown status'
    END;
    SET v_read = (SELECT COUNT(*) FROM tmp_delivery_partner);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_delivery_partner);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.partner_id, t.reject_reason, c_job_name,
           JSON_OBJECT('partner_id', s.partner_id, 'partner_name', s.partner_name, 'phone', s.phone,
                       'vehicle_type', s.vehicle_type, 'city', s.city, 'rating', s.rating, 'status', s.status)
    FROM tmp_delivery_partner t
    JOIN food_staging.stg_delivery_partners s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    SELECT COALESCE(SUM(d.delivery_partner_key IS NULL), 0),
           COALESCE(SUM(d.delivery_partner_key IS NOT NULL
                        AND NOT (d.partner_name <=> x.partner_name AND d.phone <=> x.phone
                                 AND d.vehicle_type <=> x.vehicle_type AND d.city <=> x.city
                                 AND d.rating <=> x.rating AND d.status <=> x.status)), 0)
    INTO v_inserted, v_updated
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.partner_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_delivery_partner t WHERE t.reject_reason IS NULL) AS x
    LEFT JOIN dim_delivery_partner d ON d.partner_id = x.partner_id
    WHERE x.rn = 1;

    INSERT INTO dim_delivery_partner (partner_id, partner_name, phone, vehicle_type, city, rating, status, batch_id)
    SELECT src.partner_id, src.partner_name, src.phone, src.vehicle_type, src.city, src.rating, src.status, src.batch_id
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.partner_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_delivery_partner t WHERE t.reject_reason IS NULL) AS src
    WHERE src.rn = 1
    ON DUPLICATE KEY UPDATE
        batch_id     = IF(dim_delivery_partner.partner_name <=> src.partner_name AND dim_delivery_partner.phone <=> src.phone
                          AND dim_delivery_partner.vehicle_type <=> src.vehicle_type AND dim_delivery_partner.city <=> src.city
                          AND dim_delivery_partner.rating <=> src.rating AND dim_delivery_partner.status <=> src.status, dim_delivery_partner.batch_id, src.batch_id),
        partner_name = src.partner_name,
        phone        = src.phone,
        vehicle_type = src.vehicle_type,
        city         = src.city,
        rating       = src.rating,
        status       = src.status;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_delivery_partner;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

-- ----------------------------------------------------------------------------
-- dim_menu_item (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_dim_menu_item(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_dim_menu_item';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_menu_items';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_menu_item;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_menu_items);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_menu_item;
    CREATE TEMPORARY TABLE tmp_menu_item AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.item_id))       AS item_id,
           UPPER(food_staging.fn_clean_text(s.restaurant_id)) AS restaurant_id,
           food_staging.fn_clean_text(s.item_name)            AS item_name,
           food_staging.fn_title_case(s.category)             AS category,
           food_staging.fn_to_flag(s.is_veg)                  AS is_veg,
           food_staging.fn_to_decimal(s.base_price)           AS base_price,
           COALESCE(food_staging.fn_to_flag(s.is_available), 1) AS is_available,
           CAST(NULL AS CHAR(255))                            AS reject_reason
    FROM food_staging.stg_menu_items s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_menu_item
    SET reject_reason = CASE
        WHEN item_id IS NULL THEN 'missing item_id'
        WHEN restaurant_id IS NULL THEN 'missing restaurant_id'
        WHEN item_name IS NULL THEN 'missing item_name'
        WHEN category IS NULL THEN 'missing category'
        WHEN is_veg IS NULL THEN 'invalid is_veg flag'
        WHEN base_price IS NULL OR base_price <= 0 THEN 'invalid base_price'
    END;
    SET v_read = (SELECT COUNT(*) FROM tmp_menu_item);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_menu_item);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.item_id, t.reject_reason, c_job_name,
           JSON_OBJECT('item_id', s.item_id, 'restaurant_id', s.restaurant_id, 'item_name', s.item_name,
                       'category', s.category, 'is_veg', s.is_veg, 'base_price', s.base_price,
                       'is_available', s.is_available)
    FROM tmp_menu_item t
    JOIN food_staging.stg_menu_items s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    SELECT COALESCE(SUM(d.menu_item_key IS NULL), 0),
           COALESCE(SUM(d.menu_item_key IS NOT NULL
                        AND NOT (d.restaurant_id <=> x.restaurant_id AND d.item_name <=> x.item_name
                                 AND d.category <=> x.category AND d.is_veg <=> x.is_veg
                                 AND d.base_price <=> x.base_price AND d.is_available <=> x.is_available)), 0)
    INTO v_inserted, v_updated
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.item_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_menu_item t WHERE t.reject_reason IS NULL) AS x
    LEFT JOIN dim_menu_item d ON d.item_id = x.item_id
    WHERE x.rn = 1;

    INSERT INTO dim_menu_item (item_id, restaurant_id, item_name, category, is_veg, base_price, is_available, batch_id)
    SELECT src.item_id, src.restaurant_id, src.item_name, src.category, src.is_veg, src.base_price,
           src.is_available, src.batch_id
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.item_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_menu_item t WHERE t.reject_reason IS NULL) AS src
    WHERE src.rn = 1
    ON DUPLICATE KEY UPDATE
        batch_id      = IF(dim_menu_item.restaurant_id <=> src.restaurant_id AND dim_menu_item.item_name <=> src.item_name
                           AND dim_menu_item.category <=> src.category AND dim_menu_item.is_veg <=> src.is_veg
                           AND dim_menu_item.base_price <=> src.base_price AND dim_menu_item.is_available <=> src.is_available,
                           dim_menu_item.batch_id, src.batch_id),
        restaurant_id = src.restaurant_id,
        item_name     = src.item_name,
        category      = src.category,
        is_veg        = src.is_veg,
        base_price    = src.base_price,
        is_available  = src.is_available;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_menu_item;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

-- ----------------------------------------------------------------------------
-- dim_restaurant (SCD Type 2)
-- Batches in the delta are applied one at a time in date order, each with its
-- business date as the effective date, so a backfill rebuilds full history.
-- The first version of a restaurant is valid from 1900-01-01, so orders placed
-- before the restaurant first appeared in a snapshot still resolve. Re-running
-- a batch older than the current version leaves history untouched (use
-- run_pipeline.py --full-refresh to rebuild history after late corrections).
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_dim_restaurant(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_dim_restaurant';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_restaurants';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_batch VARCHAR(64);
    DECLARE v_effective DATETIME;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_restaurant, tmp_restaurant_latest;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_restaurants);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_restaurant, tmp_restaurant_latest;
    CREATE TEMPORARY TABLE tmp_restaurant AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.restaurant_id))   AS restaurant_id,
           food_staging.fn_clean_text(s.name)                   AS restaurant_name,
           food_staging.fn_title_case(s.cuisine_type)           AS cuisine_type,
           food_staging.fn_clean_text(s.city)                   AS city,
           food_staging.fn_clean_text(s.area)                   AS area,
           IF(food_staging.fn_to_decimal(s.rating) BETWEEN 1 AND 5,
              food_staging.fn_to_decimal(s.rating), NULL)       AS rating,
           IF(food_staging.fn_to_decimal(s.cost_for_two) > 0,
              food_staging.fn_to_decimal(s.cost_for_two), NULL) AS cost_for_two,
           COALESCE(food_staging.fn_to_flag(s.is_active_partner), 1) AS is_active_partner,
           CAST(NULL AS CHAR(32))                               AS row_hash,
           CAST(NULL AS CHAR(255))                              AS reject_reason
    FROM food_staging.stg_restaurants s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_restaurant
    SET reject_reason = CASE
            WHEN restaurant_id IS NULL THEN 'missing restaurant_id'
            WHEN restaurant_name IS NULL THEN 'missing restaurant name'
            WHEN cuisine_type IS NULL THEN 'missing cuisine_type'
            WHEN city IS NULL THEN 'missing city'
            WHEN area IS NULL THEN 'missing area'
        END,
        row_hash = MD5(CONCAT_WS('|', COALESCE(restaurant_name, ''), COALESCE(cuisine_type, ''),
                                 COALESCE(city, ''), COALESCE(area, ''), COALESCE(rating, ''),
                                 COALESCE(cost_for_two, ''), is_active_partner));
    SET v_read = (SELECT COUNT(*) FROM tmp_restaurant);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_restaurant);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.restaurant_id, t.reject_reason, c_job_name,
           JSON_OBJECT('restaurant_id', s.restaurant_id, 'name', s.name, 'cuisine_type', s.cuisine_type,
                       'city', s.city, 'area', s.area, 'rating', s.rating, 'cost_for_two', s.cost_for_two,
                       'is_active_partner', s.is_active_partner)
    FROM tmp_restaurant t
    JOIN food_staging.stg_restaurants s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    -- Latest valid row per restaurant within each batch
    CREATE TEMPORARY TABLE tmp_restaurant_latest AS
    SELECT x.*
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.batch_id, t.restaurant_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_restaurant t WHERE t.reject_reason IS NULL) AS x
    WHERE x.rn = 1;

    SET v_batch = (SELECT MIN(batch_id) FROM tmp_restaurant_latest);
    WHILE v_batch IS NOT NULL DO
        SET v_effective = food_control.fn_batch_date(v_batch);

        -- Close the current version of every restaurant whose tracked attributes changed
        UPDATE dim_restaurant d
        JOIN tmp_restaurant_latest s ON s.restaurant_id = d.restaurant_id AND s.batch_id = v_batch
        SET d.is_current = 0, d.valid_to = v_effective
        -- A replayed batch older than the current version must not rewrite newer history
        WHERE d.is_current = 1 AND d.row_hash <> s.row_hash AND d.valid_from <= v_effective;
        SET v_updated = v_updated + ROW_COUNT();

        -- Open a version for new restaurants and for those just closed
        INSERT INTO dim_restaurant
            (restaurant_id, restaurant_name, cuisine_type, city, area, rating, cost_for_two,
             is_active_partner, row_hash, scd_version, valid_from, batch_id)
        SELECT s.restaurant_id, s.restaurant_name, s.cuisine_type, s.city, s.area, s.rating, s.cost_for_two,
               s.is_active_partner, s.row_hash,
               COALESCE(v.max_version, 0) + 1,
               IF(v.max_version IS NULL, '1900-01-01 00:00:00', v_effective),
               s.batch_id
        FROM tmp_restaurant_latest s
        LEFT JOIN (SELECT restaurant_id, MAX(scd_version) AS max_version, MAX(is_current) AS has_current
                   FROM dim_restaurant GROUP BY restaurant_id) AS v ON v.restaurant_id = s.restaurant_id
        WHERE s.batch_id = v_batch AND COALESCE(v.has_current, 0) = 0;
        SET v_inserted = v_inserted + ROW_COUNT();

        SET v_batch = (SELECT MIN(batch_id) FROM tmp_restaurant_latest WHERE batch_id > v_batch);
    END WHILE;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_restaurant, tmp_restaurant_latest;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

-- ----------------------------------------------------------------------------
-- dim_customer (SCD Type 2) - same approach as dim_restaurant
-- ----------------------------------------------------------------------------
CREATE PROCEDURE sp_load_dim_customer(IN p_batch_id VARCHAR(64))
BEGIN
    DECLARE c_job_name VARCHAR(100) DEFAULT 'sp_load_dim_customer';
    DECLARE c_source   VARCHAR(64)  DEFAULT 'stg_customers';
    DECLARE v_job_id BIGINT;
    DECLARE v_from_id, v_to_id BIGINT;
    DECLARE v_read, v_inserted, v_updated, v_rejected INT DEFAULT 0;
    DECLARE v_batch VARCHAR(64);
    DECLARE v_effective DATETIME;
    DECLARE v_error_code VARCHAR(20);
    DECLARE v_error_message TEXT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_error_code = MYSQL_ERRNO, v_error_message = MESSAGE_TEXT;
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_customer, tmp_customer_latest;
        CALL food_control.sp_job_fail(v_job_id, p_batch_id, c_job_name, v_error_code, v_error_message);
        RESIGNAL;
    END;

    CALL food_control.sp_job_start(c_job_name, p_batch_id, v_job_id);
    SET v_from_id = food_control.fn_get_watermark(c_source);
    SET v_to_id = (SELECT COALESCE(MAX(stg_id), v_from_id) FROM food_staging.stg_customers);

    START TRANSACTION;

    DROP TEMPORARY TABLE IF EXISTS tmp_customer, tmp_customer_latest;
    CREATE TEMPORARY TABLE tmp_customer AS
    SELECT s.stg_id,
           s.batch_id,
           UPPER(food_staging.fn_clean_text(s.customer_id))  AS customer_id,
           food_staging.fn_clean_text(s.customer_name)       AS customer_name,
           IF(LOWER(food_staging.fn_clean_text(s.email)) REGEXP '^[^@ ]+@[^@ ]+[.][a-z]{2,}$',
              LOWER(food_staging.fn_clean_text(s.email)), NULL) AS email,
           food_staging.fn_clean_phone(s.phone)               AS phone,
           food_staging.fn_clean_text(s.city)                 AS city,
           food_staging.fn_clean_text(s.state)                AS state,
           IF(TRIM(s.pincode) REGEXP '^[1-9][0-9]{5}$', TRIM(s.pincode), NULL) AS pincode,
           DATE(food_staging.fn_to_datetime(s.signup_date))   AS signup_date,
           CAST(NULL AS CHAR(32))                             AS row_hash,
           CAST(NULL AS CHAR(255))                            AS reject_reason
    FROM food_staging.stg_customers s
    WHERE s.stg_id > v_from_id AND s.stg_id <= v_to_id
      AND NOT EXISTS (SELECT 1 FROM food_control.etl_batch_hold h WHERE h.batch_id = s.batch_id);

    UPDATE tmp_customer
    SET reject_reason = CASE
            WHEN customer_id IS NULL THEN 'missing customer_id'
            WHEN customer_name IS NULL THEN 'missing customer_name'
            WHEN city IS NULL THEN 'missing city'
            WHEN state IS NULL THEN 'missing state'
        END,
        row_hash = MD5(CONCAT_WS('|', COALESCE(customer_name, ''), COALESCE(email, ''), COALESCE(phone, ''),
                                 COALESCE(city, ''), COALESCE(state, ''), COALESCE(pincode, ''),
                                 COALESCE(signup_date, '')));
    SET v_read = (SELECT COUNT(*) FROM tmp_customer);

    DELETE FROM food_staging.stg_rejected_records
    WHERE source_table = c_source AND batch_id IN (SELECT batch_id FROM tmp_customer);
    INSERT INTO food_staging.stg_rejected_records
        (batch_id, source_table, stg_id, record_identifier, rejection_reason, rejected_by, raw_payload)
    SELECT t.batch_id, c_source, t.stg_id, t.customer_id, t.reject_reason, c_job_name,
           JSON_OBJECT('customer_id', s.customer_id, 'customer_name', s.customer_name, 'email', s.email,
                       'phone', s.phone, 'city', s.city, 'state', s.state, 'pincode', s.pincode,
                       'signup_date', s.signup_date)
    FROM tmp_customer t
    JOIN food_staging.stg_customers s ON s.stg_id = t.stg_id
    WHERE t.reject_reason IS NOT NULL;
    SET v_rejected = ROW_COUNT();

    CREATE TEMPORARY TABLE tmp_customer_latest AS
    SELECT x.*
    FROM (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.batch_id, t.customer_id ORDER BY t.stg_id DESC) AS rn
          FROM tmp_customer t WHERE t.reject_reason IS NULL) AS x
    WHERE x.rn = 1;

    SET v_batch = (SELECT MIN(batch_id) FROM tmp_customer_latest);
    WHILE v_batch IS NOT NULL DO
        SET v_effective = food_control.fn_batch_date(v_batch);

        UPDATE dim_customer d
        JOIN tmp_customer_latest s ON s.customer_id = d.customer_id AND s.batch_id = v_batch
        SET d.is_current = 0, d.valid_to = v_effective
        -- A replayed batch older than the current version must not rewrite newer history
        WHERE d.is_current = 1 AND d.row_hash <> s.row_hash AND d.valid_from <= v_effective;
        SET v_updated = v_updated + ROW_COUNT();

        INSERT INTO dim_customer
            (customer_id, customer_name, email, phone, city, state, pincode, signup_date,
             row_hash, scd_version, valid_from, batch_id)
        SELECT s.customer_id, s.customer_name, s.email, s.phone, s.city, s.state, s.pincode, s.signup_date,
               s.row_hash,
               COALESCE(v.max_version, 0) + 1,
               IF(v.max_version IS NULL, '1900-01-01 00:00:00', v_effective),
               s.batch_id
        FROM tmp_customer_latest s
        LEFT JOIN (SELECT customer_id, MAX(scd_version) AS max_version, MAX(is_current) AS has_current
                   FROM dim_customer GROUP BY customer_id) AS v ON v.customer_id = s.customer_id
        WHERE s.batch_id = v_batch AND COALESCE(v.has_current, 0) = 0;
        SET v_inserted = v_inserted + ROW_COUNT();

        SET v_batch = (SELECT MIN(batch_id) FROM tmp_customer_latest WHERE batch_id > v_batch);
    END WHILE;

    CALL food_control.sp_set_watermark(c_source, v_to_id);
    COMMIT;
    DROP TEMPORARY TABLE tmp_customer, tmp_customer_latest;
    CALL food_control.sp_job_finish(v_job_id, v_read, v_inserted, v_updated, v_rejected);
END$$

DELIMITER ;
