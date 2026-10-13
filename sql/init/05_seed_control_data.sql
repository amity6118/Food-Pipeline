-- ============================================================================
-- 05_seed_control_data.sql
-- Description: Seeds pipeline metadata, watermarks, DQ rules, and standard dimensions
-- ============================================================================

USE food_control;

-- ----------------------------------------------------------------------------
-- 1. Seed Pipeline Metadata & Watermarks
-- ----------------------------------------------------------------------------
INSERT INTO pipeline_metadata (metadata_key, metadata_value, description)
VALUES 
    ('last_order_timestamp', '2023-01-01 00:00:00', 'High watermark for incremental order ingestion'),
    ('last_successful_batch_id', 'INIT_BATCH_000', 'Last completed batch identifier'),
    ('pipeline_version', '1.0.0', 'Current ETL pipeline engine release version')
ON DUPLICATE KEY UPDATE 
    metadata_value = VALUES(metadata_value),
    description = VALUES(description);

-- ----------------------------------------------------------------------------
-- 2. Seed Data Quality Rules (Table-Driven DQ Framework)
-- ----------------------------------------------------------------------------
DELETE FROM dq_rules;

INSERT INTO dq_rules (rule_id, rule_name, target_database, target_table, column_name, rule_type, condition_sql, severity, is_active, description)
VALUES
    -- Staging Layer Checks
    (1, 'stg_orders_null_order_id', 'food_staging', 'stg_orders', 'order_id', 'NULL_CHECK',
     'SELECT COUNT(*) FROM food_staging.stg_orders WHERE order_id IS NULL OR TRIM(order_id) = ""', 'FAIL', 1,
     'Order ID must not be null or empty in staging'),

    (2, 'stg_orders_null_customer_id', 'food_staging', 'stg_orders', 'customer_id', 'NULL_CHECK',
     'SELECT COUNT(*) FROM food_staging.stg_orders WHERE customer_id IS NULL OR TRIM(customer_id) = ""', 'FAIL', 1,
     'Customer ID must not be null or empty in staging orders'),

    (3, 'stg_orders_invalid_gross_amount', 'food_staging', 'stg_orders', 'gross_amount', 'RANGE_CHECK',
     'SELECT COUNT(*) FROM food_staging.stg_orders WHERE CAST(gross_amount AS DECIMAL(10,2)) <= 0 OR gross_amount IS NULL', 'WARN', 1,
     'Order gross amount must be strictly greater than zero in staging'),

    -- Warehouse Fact Layer Checks
    (4, 'dw_fact_orders_null_keys', 'food_dw', 'fact_orders', 'customer_key', 'NULL_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders WHERE customer_key IS NULL OR restaurant_key IS NULL OR delivery_partner_key IS NULL', 'FAIL', 1,
     'All foreign dimension keys in fact_orders must be populated'),

    (5, 'dw_fact_orders_net_amount_non_negative', 'food_dw', 'fact_orders', 'net_amount', 'RANGE_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders WHERE net_amount < 0', 'FAIL', 1,
     'Calculated net amount in fact_orders must not be negative'),

    (6, 'dw_fact_orders_rating_range', 'food_dw', 'fact_orders', 'rating', 'RANGE_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders WHERE rating IS NOT NULL AND (rating < 1.0 OR rating > 5.0)', 'WARN', 1,
     'Order rating score must be within 1.0 and 5.0 stars'),

    (7, 'dw_fact_orders_delivery_minutes_range', 'food_dw', 'fact_orders', 'delivery_minutes', 'RANGE_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders WHERE delivery_minutes < 0 OR delivery_minutes > 300', 'WARN', 1,
     'Delivery duration must be between 0 and 300 minutes'),

    (8, 'dw_fact_order_items_orphan_check', 'food_dw', 'fact_order_items', 'order_key', 'REFERENTIAL_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_order_items oi LEFT JOIN food_dw.fact_orders o ON oi.order_key = o.order_key WHERE o.order_key IS NULL', 'FAIL', 1,
     'Order items must not reference non-existent orders'),

    (9, 'dw_fact_orders_orphan_customer_check', 'food_dw', 'fact_orders', 'customer_key', 'REFERENTIAL_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders o LEFT JOIN food_dw.dim_customer c ON o.customer_key = c.customer_key WHERE c.customer_key IS NULL', 'FAIL', 1,
     'Orders must not reference non-existent customers in dim_customer'),

    (10, 'dw_freshness_orders_check', 'food_dw', 'fact_orders', 'order_datetime', 'FRESHNESS_CHECK',
     'SELECT COUNT(*) FROM food_dw.fact_orders WHERE order_datetime > NOW() + INTERVAL 1 DAY', 'FAIL', 1,
     'Fact order dates cannot be in the future beyond 24 hours');

-- ----------------------------------------------------------------------------
-- 3. Seed Payment Method Static Dimension
-- ----------------------------------------------------------------------------
USE food_dw;

INSERT INTO dim_payment_method (payment_method_id, method_name, method_category)
VALUES
    ('PM_UPI', 'UPI / QR Code', 'UPI'),
    ('PM_CC', 'Credit Card', 'CARD'),
    ('PM_DC', 'Debit Card', 'CARD'),
    ('PM_NB', 'Net Banking', 'NETBANKING'),
    ('PM_COD', 'Cash on Delivery', 'COD'),
    ('PM_WALLET', 'Digital Wallet', 'WALLET')
ON DUPLICATE KEY UPDATE
    method_name = VALUES(method_name),
    method_category = VALUES(method_category);
