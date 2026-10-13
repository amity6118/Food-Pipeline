-- ============================================================================
-- 06_create_dim_date.sql
-- Holiday reference data + sp_populate_dim_date, then populates dim_date for
-- 2023-01-01 .. 2027-12-31.
--
-- Holidays are table-driven (ref_indian_holidays) rather than hard-coded, so a
-- correction or a new year is a data change, not a code change. Lunar festival
-- dates follow the Government of India gazetted holiday lists.
-- ============================================================================

USE food_dw;

-- ----------------------------------------------------------------------------
-- Holiday reference table. A date can carry several entries
-- (e.g. 2025-10-02 is both Gandhi Jayanti and Dussehra).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref_indian_holidays (
    holiday_date  DATE         NOT NULL,
    holiday_name  VARCHAR(100) NOT NULL,
    holiday_type  ENUM('NATIONAL', 'FESTIVAL') NOT NULL
                  COMMENT 'NATIONAL = gazetted national holiday; FESTIVAL = major festival / high-demand day',
    PRIMARY KEY (holiday_date, holiday_name)
) ENGINE=InnoDB;

-- Fixed-date holidays, generated for each year. The SELECT is wrapped in a
-- derived table so MySQL does not parse ON DUPLICATE KEY as a join condition.
INSERT INTO ref_indian_holidays (holiday_date, holiday_name, holiday_type)
SELECT src.holiday_date, src.holiday_name, src.holiday_type
FROM (
    SELECT MAKEDATE(y.yr, 1) + INTERVAL (h.mon - 1) MONTH + INTERVAL (h.dy - 1) DAY AS holiday_date,
           h.holiday_name,
           h.holiday_type
    FROM (SELECT 2023 AS yr UNION ALL SELECT 2024 UNION ALL SELECT 2025
          UNION ALL SELECT 2026 UNION ALL SELECT 2027) AS y
    CROSS JOIN (
        SELECT  1 AS mon,  1 AS dy, 'New Year''s Day'  AS holiday_name, 'FESTIVAL' AS holiday_type UNION ALL
        SELECT  1,        26,       'Republic Day',                     'NATIONAL'                 UNION ALL
        SELECT  8,        15,       'Independence Day',                 'NATIONAL'                 UNION ALL
        SELECT 10,         2,       'Gandhi Jayanti',                   'NATIONAL'                 UNION ALL
        SELECT 12,        25,       'Christmas',                        'FESTIVAL'                 UNION ALL
        SELECT 12,        31,       'New Year''s Eve',                  'FESTIVAL'
    ) AS h
) AS src
ON DUPLICATE KEY UPDATE holiday_type = src.holiday_type;

-- Lunar-calendar festivals (dates change every year)
INSERT INTO ref_indian_holidays (holiday_date, holiday_name, holiday_type) VALUES
    ('2023-03-08', 'Holi', 'FESTIVAL'), ('2023-04-22', 'Id-ul-Fitr', 'FESTIVAL'),
    ('2023-10-24', 'Dussehra', 'FESTIVAL'), ('2023-11-12', 'Diwali', 'FESTIVAL'),
    ('2024-03-25', 'Holi', 'FESTIVAL'), ('2024-04-11', 'Id-ul-Fitr', 'FESTIVAL'),
    ('2024-10-12', 'Dussehra', 'FESTIVAL'), ('2024-10-31', 'Diwali', 'FESTIVAL'),
    ('2025-03-14', 'Holi', 'FESTIVAL'), ('2025-03-31', 'Id-ul-Fitr', 'FESTIVAL'),
    ('2025-10-02', 'Dussehra', 'FESTIVAL'), ('2025-10-20', 'Diwali', 'FESTIVAL'),
    ('2026-03-04', 'Holi', 'FESTIVAL'), ('2026-03-21', 'Id-ul-Fitr', 'FESTIVAL'),
    ('2026-10-20', 'Dussehra', 'FESTIVAL'), ('2026-11-08', 'Diwali', 'FESTIVAL'),
    ('2027-03-23', 'Holi', 'FESTIVAL'), ('2027-03-10', 'Id-ul-Fitr', 'FESTIVAL'),
    ('2027-10-09', 'Dussehra', 'FESTIVAL'), ('2027-10-29', 'Diwali', 'FESTIVAL')
AS new
ON DUPLICATE KEY UPDATE holiday_type = new.holiday_type;

-- ----------------------------------------------------------------------------
-- sp_populate_dim_date: upserts one row per day in [p_start_date, p_end_date].
-- Safe to re-run; existing rows are refreshed (e.g. after a holiday correction).
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_populate_dim_date;

DELIMITER $$

CREATE PROCEDURE sp_populate_dim_date(IN p_start_date DATE, IN p_end_date DATE)
BEGIN
    IF p_start_date IS NULL OR p_end_date IS NULL OR p_end_date < p_start_date THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'sp_populate_dim_date: invalid date range';
    END IF;

    -- The recursive calendar CTE needs one level per day
    SET SESSION cte_max_recursion_depth = GREATEST(1000, DATEDIFF(p_end_date, p_start_date) + 1);

    INSERT INTO dim_date (
        date_key, full_date, year, quarter, quarter_name, month, month_name, month_short,
        month_label, week_of_year, day_of_month, day_of_week, day_name, day_short,
        is_weekend, is_holiday, is_festival, holiday_name
    )
    SELECT src.*
    FROM (
        WITH RECURSIVE calendar AS (
            SELECT p_start_date AS cal_date
            UNION ALL
            SELECT cal_date + INTERVAL 1 DAY FROM calendar WHERE cal_date < p_end_date
        ),
        holidays AS (
            SELECT holiday_date,
                   MAX(holiday_type = 'NATIONAL') AS is_holiday,
                   MAX(holiday_type = 'FESTIVAL') AS is_festival,
                   GROUP_CONCAT(holiday_name ORDER BY holiday_type, holiday_name SEPARATOR ' / ') AS holiday_name
            FROM ref_indian_holidays
            GROUP BY holiday_date
        )
        SELECT CAST(DATE_FORMAT(c.cal_date, '%Y%m%d') AS UNSIGNED) AS date_key,
               c.cal_date                        AS full_date,
               YEAR(c.cal_date)                  AS year,
               QUARTER(c.cal_date)               AS quarter,
               CONCAT('Q', QUARTER(c.cal_date))  AS quarter_name,
               MONTH(c.cal_date)                 AS month,
               MONTHNAME(c.cal_date)             AS month_name,
               LEFT(MONTHNAME(c.cal_date), 3)    AS month_short,
               DATE_FORMAT(c.cal_date, '%Y-%m')  AS month_label,
               WEEK(c.cal_date, 3)               AS week_of_year,
               DAY(c.cal_date)                   AS day_of_month,
               WEEKDAY(c.cal_date) + 1           AS day_of_week,
               DAYNAME(c.cal_date)               AS day_name,
               LEFT(DAYNAME(c.cal_date), 3)      AS day_short,
               WEEKDAY(c.cal_date) >= 5          AS is_weekend,
               COALESCE(h.is_holiday, 0)         AS is_holiday,
               COALESCE(h.is_festival, 0)        AS is_festival,
               h.holiday_name                    AS holiday_name
        FROM calendar AS c
        LEFT JOIN holidays AS h ON h.holiday_date = c.cal_date
    ) AS src
    ON DUPLICATE KEY UPDATE
        is_weekend   = src.is_weekend,
        is_holiday   = src.is_holiday,
        is_festival  = src.is_festival,
        holiday_name = src.holiday_name;
END$$

DELIMITER ;

CALL sp_populate_dim_date('2023-01-01', '2027-12-31');
