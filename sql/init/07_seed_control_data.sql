-- ============================================================================
-- 07_seed_control_data.sql
-- Seeds pipeline metadata (incremental watermarks) and the data quality rule
-- catalogue. Every statement is an upsert, so the script is safe to re-run.
--
-- Severity policy
--   WARN: expected, row-level dirt (the procedures reject or cleanse these rows)
--   FAIL: systemic problems that make the batch untrustworthy; stops the pipeline
-- ============================================================================

USE food_control;

-- ----------------------------------------------------------------------------
-- Pipeline metadata. Watermarks hold the last staging stg_id each table's load
-- procedure has processed; a full refresh resets them to 0.
-- ----------------------------------------------------------------------------
INSERT INTO pipeline_metadata (metadata_key, metadata_value, description) VALUES
    ('pipeline_version',                '1.0.0', 'ETL pipeline release version'),
    ('last_successful_batch_id',        'NONE',  'Batch id of the last fully successful run'),
    ('watermark.stg_customers',         '0',     'Last stg_id processed by sp_load_dim_customer'),
    ('watermark.stg_restaurants',       '0',     'Last stg_id processed by sp_load_dim_restaurant'),
    ('watermark.stg_menu_items',        '0',     'Last stg_id processed by sp_load_dim_menu_item'),
    ('watermark.stg_delivery_partners', '0',     'Last stg_id processed by sp_load_dim_delivery_partner'),
    ('watermark.stg_payment_methods',   '0',     'Last stg_id processed by sp_load_dim_payment_method'),
    ('watermark.stg_orders',            '0',     'Last stg_id processed by sp_load_fact_orders'),
    ('watermark.stg_order_items',       '0',     'Last stg_id processed by sp_load_fact_order_items')
AS new
ON DUPLICATE KEY UPDATE description = new.description;

-- ----------------------------------------------------------------------------
-- Data quality rules
-- violation_query returns one row per violation; :batch_id is bound by the engine.
-- ----------------------------------------------------------------------------
INSERT INTO dq_rules
    (rule_name, stage, rule_type, target_table, target_column, violation_query, severity, description)
VALUES
    -- ===================== STAGING (before the procedures) =====================
    ('stg_orders_batch_not_empty', 'STAGING', 'VOLUME_CHECK', 'food_staging.stg_orders', NULL,
     'SELECT 1 AS empty_batch FROM DUAL
      WHERE NOT EXISTS (SELECT 1 FROM food_staging.stg_orders WHERE batch_id = :batch_id)',
     'FAIL', 'The batch must contain at least one order'),

    ('stg_orders_order_id_not_null', 'STAGING', 'NULL_CHECK', 'food_staging.stg_orders', 'order_id',
     'SELECT stg_id FROM food_staging.stg_orders
      WHERE batch_id = :batch_id AND food_staging.fn_is_blank(order_id)',
     'FAIL', 'Every order must carry an order_id'),

    ('stg_orders_customer_id_not_null', 'STAGING', 'NULL_CHECK', 'food_staging.stg_orders', 'customer_id',
     'SELECT stg_id, order_id FROM food_staging.stg_orders
      WHERE batch_id = :batch_id AND food_staging.fn_is_blank(customer_id)',
     'WARN', 'Orders without a customer are rejected by sp_load_fact_orders'),

    ('stg_orders_order_datetime_valid', 'STAGING', 'FORMAT_CHECK', 'food_staging.stg_orders', 'order_datetime',
     'SELECT stg_id, order_id, order_datetime FROM food_staging.stg_orders
      WHERE batch_id = :batch_id AND food_staging.fn_to_datetime(order_datetime) IS NULL',
     'WARN', 'order_datetime must be a real YYYY-MM-DD HH:MM:SS timestamp'),

    ('stg_orders_gross_amount_positive', 'STAGING', 'RANGE_CHECK', 'food_staging.stg_orders', 'gross_amount',
     'SELECT stg_id, order_id, gross_amount FROM food_staging.stg_orders
      WHERE batch_id = :batch_id AND COALESCE(food_staging.fn_to_decimal(gross_amount), 0) <= 0',
     'WARN', 'gross_amount must be a number greater than zero'),

    ('stg_orders_rating_range', 'STAGING', 'RANGE_CHECK', 'food_staging.stg_orders', 'rating',
     'SELECT stg_id, order_id, rating FROM food_staging.stg_orders
      WHERE batch_id = :batch_id AND NOT food_staging.fn_is_blank(rating)
        AND COALESCE(food_staging.fn_to_decimal(rating), 0) NOT BETWEEN 1 AND 5',
     'WARN', 'Ratings, when present, must be between 1 and 5'),

    ('stg_orders_order_id_unique', 'STAGING', 'UNIQUENESS_CHECK', 'food_staging.stg_orders', 'order_id',
     'SELECT order_id, COUNT(*) AS copies FROM food_staging.stg_orders
      WHERE batch_id = :batch_id GROUP BY order_id HAVING COUNT(*) > 1',
     'WARN', 'Duplicate orders in a batch are de-duplicated by the procedures'),

    ('stg_orders_customer_exists', 'STAGING', 'REFERENTIAL_CHECK', 'food_staging.stg_orders', 'customer_id',
     'SELECT o.stg_id, o.order_id, o.customer_id FROM food_staging.stg_orders o
      WHERE o.batch_id = :batch_id AND NOT food_staging.fn_is_blank(o.customer_id)
        AND NOT EXISTS (SELECT 1 FROM food_dw.dim_customer c WHERE c.customer_id = TRIM(o.customer_id))
        AND NOT EXISTS (SELECT 1 FROM food_staging.stg_customers s
                        WHERE s.batch_id = :batch_id AND TRIM(s.customer_id) = TRIM(o.customer_id))',
     'WARN', 'Orders must reference a known customer'),

    ('stg_order_items_quantity_positive', 'STAGING', 'RANGE_CHECK', 'food_staging.stg_order_items', 'quantity',
     'SELECT stg_id, order_id, quantity FROM food_staging.stg_order_items
      WHERE batch_id = :batch_id AND COALESCE(food_staging.fn_to_int(quantity), 0) <= 0',
     'WARN', 'Item quantity must be a whole number greater than zero'),

    ('stg_restaurants_cost_for_two_positive', 'STAGING', 'RANGE_CHECK', 'food_staging.stg_restaurants', 'cost_for_two',
     'SELECT stg_id, restaurant_id, cost_for_two FROM food_staging.stg_restaurants
      WHERE batch_id = :batch_id AND COALESCE(food_staging.fn_to_decimal(cost_for_two), 0) <= 0',
     'WARN', 'cost_for_two must be positive; invalid values are loaded as NULL'),

    ('stg_delivery_partners_rating_range', 'STAGING', 'RANGE_CHECK', 'food_staging.stg_delivery_partners', 'rating',
     'SELECT stg_id, partner_id, rating FROM food_staging.stg_delivery_partners
      WHERE batch_id = :batch_id AND COALESCE(food_staging.fn_to_decimal(rating), 0) NOT BETWEEN 1 AND 5',
     'WARN', 'Partner ratings must be between 1 and 5; invalid values are loaded as NULL'),

    ('stg_customers_pincode_format', 'STAGING', 'FORMAT_CHECK', 'food_staging.stg_customers', 'pincode',
     'SELECT stg_id, customer_id, pincode FROM food_staging.stg_customers
      WHERE batch_id = :batch_id AND NOT food_staging.fn_is_blank(pincode)
        AND TRIM(pincode) NOT REGEXP ''^[1-9][0-9]{5}$''',
     'WARN', 'Pincodes must be six digits; invalid values are loaded as NULL'),

    -- ===================== WAREHOUSE (after the procedures) =====================
    ('dw_fact_orders_net_amount_formula', 'WAREHOUSE', 'RECONCILIATION_CHECK', 'food_dw.fact_orders', 'net_amount',
     'SELECT order_id, gross_amount, discount, delivery_fee, net_amount FROM food_dw.fact_orders
      WHERE batch_id = :batch_id AND ABS(net_amount - (gross_amount - discount + delivery_fee)) > 0.01',
     'FAIL', 'net_amount must equal gross_amount - discount + delivery_fee'),

    ('dw_fact_orders_amounts_valid', 'WAREHOUSE', 'RANGE_CHECK', 'food_dw.fact_orders', 'gross_amount',
     'SELECT order_id, gross_amount, discount, delivery_fee FROM food_dw.fact_orders
      WHERE batch_id = :batch_id
        AND (gross_amount <= 0 OR discount < 0 OR discount > gross_amount OR delivery_fee < 0)',
     'FAIL', 'Amounts must be positive and discounts cannot exceed the gross amount'),

    ('dw_fact_orders_rating_range', 'WAREHOUSE', 'RANGE_CHECK', 'food_dw.fact_orders', 'rating',
     'SELECT order_id, rating FROM food_dw.fact_orders
      WHERE batch_id = :batch_id AND rating IS NOT NULL AND rating NOT BETWEEN 1 AND 5',
     'FAIL', 'Loaded ratings must be between 1 and 5'),

    ('dw_fact_orders_delivery_minutes_range', 'WAREHOUSE', 'RANGE_CHECK', 'food_dw.fact_orders', 'delivery_minutes',
     'SELECT order_id, delivery_minutes FROM food_dw.fact_orders
      WHERE batch_id = :batch_id AND delivery_minutes NOT BETWEEN 1 AND 180',
     'WARN', 'Delivery time should be between 1 and 180 minutes'),

    ('dw_fact_orders_not_future_dated', 'WAREHOUSE', 'FRESHNESS_CHECK', 'food_dw.fact_orders', 'order_datetime',
     'SELECT order_id, order_datetime FROM food_dw.fact_orders
      WHERE batch_id = :batch_id AND order_datetime > NOW() + INTERVAL 1 DAY',
     'FAIL', 'Orders cannot be dated more than a day in the future'),

    ('dw_fact_orders_freshness', 'WAREHOUSE', 'FRESHNESS_CHECK', 'food_dw.fact_orders', 'order_datetime',
     'SELECT MAX(order_datetime) AS latest_order FROM food_dw.fact_orders
      HAVING MAX(order_datetime) IS NULL OR MAX(order_datetime) < NOW() - INTERVAL 2 DAY',
     'WARN', 'The warehouse should hold orders from the last two days (expected to warn on backfills)'),

    ('dw_fact_orders_have_items', 'WAREHOUSE', 'REFERENTIAL_CHECK', 'food_dw.fact_orders', 'order_key',
     'SELECT o.order_id FROM food_dw.fact_orders o
      WHERE o.batch_id = :batch_id
        AND NOT EXISTS (SELECT 1 FROM food_dw.fact_order_items i WHERE i.order_key = o.order_key)',
     'WARN', 'Every order should have at least one order item'),

    ('dw_fact_order_items_match_gross', 'WAREHOUSE', 'RECONCILIATION_CHECK', 'food_dw.fact_order_items', 'line_total',
     'SELECT o.order_id, o.gross_amount, SUM(i.line_total) AS items_total
      FROM food_dw.fact_orders o JOIN food_dw.fact_order_items i ON i.order_key = o.order_key
      WHERE o.batch_id = :batch_id
      GROUP BY o.order_id, o.gross_amount
      HAVING ABS(SUM(i.line_total) - o.gross_amount) > 0.01',
     'WARN', 'Sum of line totals should equal the order gross amount')
AS new
ON DUPLICATE KEY UPDATE
    stage           = new.stage,
    rule_type       = new.rule_type,
    target_table    = new.target_table,
    target_column   = new.target_column,
    violation_query = new.violation_query,
    severity        = new.severity,
    description     = new.description;
