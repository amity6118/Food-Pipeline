-- ============================================================================
-- sp_populate_dim_date.sql
-- Description: Generates a complete Date Dimension for 2023-01-01 to 2027-12-31
-- Features: Calendar metadata, weekend flags, and major Indian national/cultural holidays
-- ============================================================================

USE food_dw;

DROP PROCEDURE IF EXISTS sp_populate_dim_date;

DELIMITER $$

CREATE PROCEDURE sp_populate_dim_date(
    IN p_start_date DATE,
    IN p_end_date DATE
)
BEGIN
    DECLARE v_current_date DATE;
    DECLARE v_date_key INT;
    DECLARE v_day_of_week TINYINT;
    DECLARE v_is_weekend TINYINT(1);
    DECLARE v_is_holiday TINYINT(1);
    DECLARE v_holiday_name VARCHAR(100);

    -- Default range 2023-01-01 to 2027-12-31 if nulls passed
    SET v_current_date = COALESCE(p_start_date, '2023-01-01');
    IF p_end_date IS NULL THEN
        SET p_end_date = '2027-12-31';
    END IF;

    -- Disable autocommit for bulk load performance
    START TRANSACTION;

    WHILE v_current_date <= p_end_date DO
        -- Date Key in YYYYMMDD format
        SET v_date_key = YEAR(v_current_date) * 10000 + MONTH(v_current_date) * 100 + DAY(v_current_date);
        
        -- Day of week: 1=Sunday, 7=Saturday
        SET v_day_of_week = DAYOFWEEK(v_current_date);
        SET v_is_weekend = IF(v_day_of_week IN (1, 7), 1, 0);

        -- Initialize Holiday flags
        SET v_is_holiday = 0;
        SET v_holiday_name = NULL;

        -- 1. Fixed National Holidays
        IF MONTH(v_current_date) = 1 AND DAY(v_current_date) = 1 THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'New Year\'s Day';
        ELSEIF MONTH(v_current_date) = 1 AND DAY(v_current_date) = 26 THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Republic Day';
        ELSEIF MONTH(v_current_date) = 8 AND DAY(v_current_date) = 15 THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Independence Day';
        ELSEIF MONTH(v_current_date) = 10 AND DAY(v_current_date) = 2 THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Gandhi Jayanti';
        ELSEIF MONTH(v_current_date) = 12 AND DAY(v_current_date) = 25 THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Christmas Day';

        -- 2. Major Lunar/Cultural Indian Festivals (2023 - 2027 mapping)
        -- Holi
        ELSEIF v_current_date IN ('2023-03-08', '2024-03-25', '2025-03-14', '2026-03-04', '2027-03-23') THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Holi';
        -- Eid-ul-Fitr
        ELSEIF v_current_date IN ('2023-04-22', '2024-04-11', '2025-03-31', '2026-03-20', '2027-03-10') THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Eid-ul-Fitr';
        -- Dussehra (Vijayadashami)
        ELSEIF v_current_date IN ('2023-10-24', '2024-10-12', '2025-10-02', '2026-10-20', '2027-10-10') THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Dussehra';
        -- Diwali (Deepavali)
        ELSEIF v_current_date IN ('2023-11-12', '2024-11-01', '2025-10-20', '2026-11-08', '2027-10-29') THEN
            SET v_is_holiday = 1;
            SET v_holiday_name = 'Diwali';
        END IF;

        -- Insert or Update date dimension record
        INSERT INTO dim_date (
            date_key,
            full_date,
            year,
            quarter,
            month,
            month_name,
            day,
            day_name,
            day_of_week,
            is_weekend,
            is_holiday,
            holiday_name
        ) VALUES (
            v_date_key,
            v_current_date,
            YEAR(v_current_date),
            QUARTER(v_current_date),
            MONTH(v_current_date),
            DATE_FORMAT(v_current_date, '%M'),
            DAY(v_current_date),
            DATE_FORMAT(v_current_date, '%W'),
            v_day_of_week,
            v_is_weekend,
            v_is_holiday,
            v_holiday_name
        )
        ON DUPLICATE KEY UPDATE
            is_weekend = VALUES(is_weekend),
            is_holiday = VALUES(is_holiday),
            holiday_name = VALUES(holiday_name);

        SET v_current_date = ADDDATE(v_current_date, INTERVAL 1 DAY);
    END WHILE;

    COMMIT;
    SELECT CONCAT('Successfully populated dim_date from ', p_start_date, ' to ', p_end_date) AS result_message;
END$$

DELIMITER ;
