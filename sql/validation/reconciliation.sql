-- ============================================================================
-- reconciliation.sql
-- Row-count reconciliation between staging and the warehouse, per batch.
-- Every distinct record staged must end up either loaded or rejected:
--
--     staged (distinct natural keys) = loaded + rejected
--
-- status: OK | MISMATCH | HELD (batch held back by a failed staging DQ check)
--
-- Run:  docker exec -i food_order_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table' < sql/validation/reconciliation.sql
-- ============================================================================

-- 1. Orders per batch
SELECT 'fact_orders' AS target,
       s.batch_id,
       s.staged,
       COALESCE(l.loaded, 0)   AS loaded,
       COALESCE(r.rejected, 0) AS rejected,
       CASE
           WHEN h.batch_id IS NOT NULL THEN 'HELD'
           WHEN s.staged = COALESCE(l.loaded, 0) + COALESCE(r.rejected, 0) THEN 'OK'
           ELSE 'MISMATCH'
       END AS status
FROM (SELECT batch_id, COUNT(DISTINCT UPPER(TRIM(order_id))) AS staged
      FROM food_staging.stg_orders GROUP BY batch_id) AS s
LEFT JOIN (SELECT batch_id, COUNT(*) AS loaded
           FROM food_dw.fact_orders GROUP BY batch_id) AS l ON l.batch_id = s.batch_id
LEFT JOIN (SELECT batch_id, COUNT(DISTINCT record_identifier) AS rejected
           FROM food_staging.stg_rejected_records WHERE source_table = 'stg_orders'
           GROUP BY batch_id) AS r ON r.batch_id = s.batch_id
LEFT JOIN food_control.etl_batch_hold AS h ON h.batch_id = s.batch_id
ORDER BY s.batch_id;

-- 2. Order items per batch (grain: order + menu item)
SELECT 'fact_order_items' AS target,
       s.batch_id,
       s.staged,
       COALESCE(l.loaded, 0)   AS loaded,
       COALESCE(r.rejected, 0) AS rejected,
       CASE
           WHEN h.batch_id IS NOT NULL THEN 'HELD'
           WHEN s.staged = COALESCE(l.loaded, 0) + COALESCE(r.rejected, 0) THEN 'OK'
           ELSE 'MISMATCH'
       END AS status
FROM (SELECT batch_id, COUNT(DISTINCT UPPER(TRIM(order_id)), UPPER(TRIM(item_id))) AS staged
      FROM food_staging.stg_order_items GROUP BY batch_id) AS s
LEFT JOIN (SELECT batch_id, COUNT(*) AS loaded
           FROM food_dw.fact_order_items GROUP BY batch_id) AS l ON l.batch_id = s.batch_id
LEFT JOIN (SELECT batch_id, COUNT(DISTINCT record_identifier) AS rejected
           FROM food_staging.stg_rejected_records WHERE source_table = 'stg_order_items'
           GROUP BY batch_id) AS r ON r.batch_id = s.batch_id
LEFT JOIN food_control.etl_batch_hold AS h ON h.batch_id = s.batch_id
ORDER BY s.batch_id;

-- 3. Dimensions: every natural key ever staged (outside held batches) is in the
--    dimension, or was only ever rejected
SELECT target, staged_keys, dw_keys, rejected_only_keys,
       IF(staged_keys = dw_keys + rejected_only_keys, 'OK', 'MISMATCH') AS status
FROM (
    SELECT 'dim_customer' AS target,
           (SELECT COUNT(DISTINCT UPPER(TRIM(customer_id))) FROM food_staging.stg_customers
             WHERE NOT food_staging.fn_is_blank(customer_id)
               AND batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)) AS staged_keys,
           (SELECT COUNT(DISTINCT customer_id) FROM food_dw.dim_customer) AS dw_keys,
           (SELECT COUNT(DISTINCT record_identifier) FROM food_staging.stg_rejected_records
             WHERE source_table = 'stg_customers' AND record_identifier IS NOT NULL
               AND record_identifier NOT IN (SELECT customer_id FROM food_dw.dim_customer)) AS rejected_only_keys
    UNION ALL
    SELECT 'dim_restaurant',
           (SELECT COUNT(DISTINCT UPPER(TRIM(restaurant_id))) FROM food_staging.stg_restaurants
             WHERE NOT food_staging.fn_is_blank(restaurant_id)
               AND batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)),
           (SELECT COUNT(DISTINCT restaurant_id) FROM food_dw.dim_restaurant),
           (SELECT COUNT(DISTINCT record_identifier) FROM food_staging.stg_rejected_records
             WHERE source_table = 'stg_restaurants' AND record_identifier IS NOT NULL
               AND record_identifier NOT IN (SELECT restaurant_id FROM food_dw.dim_restaurant))
    UNION ALL
    SELECT 'dim_menu_item',
           (SELECT COUNT(DISTINCT UPPER(TRIM(item_id))) FROM food_staging.stg_menu_items
             WHERE NOT food_staging.fn_is_blank(item_id)
               AND batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)),
           (SELECT COUNT(*) FROM food_dw.dim_menu_item),
           (SELECT COUNT(DISTINCT record_identifier) FROM food_staging.stg_rejected_records
             WHERE source_table = 'stg_menu_items' AND record_identifier IS NOT NULL
               AND record_identifier NOT IN (SELECT item_id FROM food_dw.dim_menu_item))
    UNION ALL
    SELECT 'dim_delivery_partner',
           (SELECT COUNT(DISTINCT UPPER(TRIM(partner_id))) FROM food_staging.stg_delivery_partners
             WHERE NOT food_staging.fn_is_blank(partner_id)
               AND batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)),
           (SELECT COUNT(*) FROM food_dw.dim_delivery_partner),
           (SELECT COUNT(DISTINCT record_identifier) FROM food_staging.stg_rejected_records
             WHERE source_table = 'stg_delivery_partners' AND record_identifier IS NOT NULL
               AND record_identifier NOT IN (SELECT partner_id FROM food_dw.dim_delivery_partner))
    UNION ALL
    SELECT 'dim_payment_method',
           (SELECT COUNT(DISTINCT UPPER(TRIM(payment_method_id))) FROM food_staging.stg_payment_methods
             WHERE NOT food_staging.fn_is_blank(payment_method_id)
               AND batch_id NOT IN (SELECT batch_id FROM food_control.etl_batch_hold)),
           (SELECT COUNT(*) FROM food_dw.dim_payment_method),
           (SELECT COUNT(DISTINCT record_identifier) FROM food_staging.stg_rejected_records
             WHERE source_table = 'stg_payment_methods' AND record_identifier IS NOT NULL
               AND record_identifier NOT IN (SELECT payment_method_id FROM food_dw.dim_payment_method))
) AS dims;

-- 4. Latest pipeline runs and DQ outcome per batch (pipeline health at a glance)
SELECT j.batch_id, j.status AS pipeline_status, j.start_time, j.duration_seconds,
       SUM(d.outcome = 'WARN') AS dq_warnings, SUM(d.outcome = 'FAIL') AS dq_failures
FROM food_control.etl_job_log j
LEFT JOIN food_control.dq_results d ON d.batch_id = j.batch_id
WHERE j.job_name = 'pipeline_run'
  AND j.job_id IN (SELECT MAX(job_id) FROM food_control.etl_job_log WHERE job_name = 'pipeline_run' GROUP BY batch_id)
GROUP BY j.job_id, j.batch_id, j.status, j.start_time, j.duration_seconds
ORDER BY j.batch_id DESC
LIMIT 10;
