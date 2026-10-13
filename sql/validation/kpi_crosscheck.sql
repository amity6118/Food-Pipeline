-- ============================================================================
-- kpi_crosscheck.sql
-- The report's headline measures computed directly in SQL. After refreshing
-- powerbi/FoodOrderAnalytics.pbip, the Executive Overview cards should match.
--
-- Run:  Get-Content sql/validation/kpi_crosscheck.sql | docker exec -i food_order_mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table'
-- ============================================================================

SELECT
    COUNT(*)                                                         AS total_orders,
    SUM(order_status = 'DELIVERED')                                  AS delivered_orders,
    SUM(IF(order_status = 'DELIVERED', gross_amount, 0))             AS gmv,
    SUM(IF(order_status = 'DELIVERED', net_amount, 0))               AS net_revenue,
    ROUND(SUM(IF(order_status = 'DELIVERED', gross_amount, 0))
          / SUM(order_status = 'DELIVERED'), 2)                      AS aov,
    ROUND(SUM(order_status = 'CANCELLED') / COUNT(*) * 100, 1)       AS cancellation_rate_pct,
    ROUND(SUM(order_status = 'DELIVERED' AND is_late = 0)
          / SUM(order_status = 'DELIVERED') * 100, 1)                AS on_time_pct,
    ROUND(AVG(rating), 2)                                            AS avg_rating
FROM food_dw.fact_orders;

-- Repeat Customer %: customers (natural key, so SCD2 versions count once) with more than one order
SELECT ROUND(SUM(orders > 1) / COUNT(*) * 100, 1) AS repeat_customer_pct
FROM (SELECT c.customer_id, COUNT(*) AS orders
      FROM food_dw.fact_orders f
      JOIN food_dw.dim_customer c ON c.customer_key = f.customer_key
      GROUP BY c.customer_id) AS per_customer;
