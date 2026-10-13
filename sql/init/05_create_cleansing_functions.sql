-- ============================================================================
-- 05_create_cleansing_functions.sql
-- Reusable cleansing functions in food_staging that turn loose VARCHAR staging
-- values into typed values. Each returns NULL for anything it cannot parse
-- instead of raising an error, so callers decide whether to reject the row.
-- Used by the warehouse load procedures and by the data quality rules.
-- ============================================================================

USE food_staging;

DROP FUNCTION IF EXISTS fn_clean_text;
DROP FUNCTION IF EXISTS fn_is_blank;
DROP FUNCTION IF EXISTS fn_to_decimal;
DROP FUNCTION IF EXISTS fn_to_int;
DROP FUNCTION IF EXISTS fn_to_datetime;
DROP FUNCTION IF EXISTS fn_to_flag;
DROP FUNCTION IF EXISTS fn_clean_phone;
DROP FUNCTION IF EXISTS fn_title_case;

DELIMITER $$

-- Trims, collapses runs of whitespace to one space; NULL for blank input.
CREATE FUNCTION fn_clean_text(p_value VARCHAR(255))
RETURNS VARCHAR(255)
DETERMINISTIC NO SQL
BEGIN
    RETURN NULLIF(REGEXP_REPLACE(TRIM(p_value), '[[:space:]]+', ' '), '');
END$$

-- 1 when the value is NULL, empty or whitespace only.
CREATE FUNCTION fn_is_blank(p_value VARCHAR(255))
RETURNS TINYINT
DETERMINISTIC NO SQL
BEGIN
    RETURN fn_clean_text(p_value) IS NULL;
END$$

-- Plain decimal number such as "120", "-15.5"; NULL otherwise.
CREATE FUNCTION fn_to_decimal(p_value VARCHAR(50))
RETURNS DECIMAL(12,2)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_text VARCHAR(255) DEFAULT fn_clean_text(p_value);
    IF v_text REGEXP '^-?[0-9]{1,10}([.][0-9]+)?$' THEN
        RETURN CAST(v_text AS DECIMAL(12,2));
    END IF;
    RETURN NULL;
END$$

-- Whole number; also accepts "38.0" (integers that pandas wrote as floats).
CREATE FUNCTION fn_to_int(p_value VARCHAR(50))
RETURNS INT
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_text VARCHAR(255) DEFAULT fn_clean_text(p_value);
    IF v_text REGEXP '^-?[0-9]{1,9}([.]0+)?$' THEN
        RETURN CAST(CAST(v_text AS DECIMAL(12,2)) AS SIGNED);
    END IF;
    RETURN NULL;
END$$

-- "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS" with real calendar/clock values.
-- Components are validated by hand instead of calling STR_TO_DATE, because
-- STR_TO_DATE raises an error on invalid dates inside INSERT under strict mode.
CREATE FUNCTION fn_to_datetime(p_value VARCHAR(100))
RETURNS DATETIME
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_text VARCHAR(255) DEFAULT fn_clean_text(p_value);
    DECLARE v_year, v_month, v_day, v_hour, v_minute, v_second INT DEFAULT 0;
    DECLARE v_month_start DATE;

    IF v_text IS NULL
       OR v_text NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$' THEN
        RETURN NULL;
    END IF;

    SET v_year  = SUBSTRING(v_text, 1, 4);
    SET v_month = SUBSTRING(v_text, 6, 2);
    SET v_day   = SUBSTRING(v_text, 9, 2);
    IF CHAR_LENGTH(v_text) = 19 THEN
        SET v_hour   = SUBSTRING(v_text, 12, 2);
        SET v_minute = SUBSTRING(v_text, 15, 2);
        SET v_second = SUBSTRING(v_text, 18, 2);
    END IF;

    IF v_year NOT BETWEEN 1900 AND 2100 OR v_month NOT BETWEEN 1 AND 12
       OR v_hour > 23 OR v_minute > 59 OR v_second > 59 THEN
        RETURN NULL;
    END IF;

    SET v_month_start = MAKEDATE(v_year, 1) + INTERVAL (v_month - 1) MONTH;
    IF v_day NOT BETWEEN 1 AND DAY(LAST_DAY(v_month_start)) THEN
        RETURN NULL;
    END IF;

    RETURN TIMESTAMP(v_month_start + INTERVAL (v_day - 1) DAY, MAKETIME(v_hour, v_minute, v_second));
END$$

-- Yes/no style values ("1", "true", "Y", ...) -> 1 / 0; NULL if unrecognised.
CREATE FUNCTION fn_to_flag(p_value VARCHAR(50))
RETURNS TINYINT
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_text VARCHAR(255) DEFAULT UPPER(fn_clean_text(p_value));
    IF v_text IN ('1', 'TRUE', 'T', 'YES', 'Y') THEN
        RETURN 1;
    ELSEIF v_text IN ('0', 'FALSE', 'F', 'NO', 'N') THEN
        RETURN 0;
    END IF;
    RETURN NULL;
END$$

-- Indian mobile number in any common format -> "+91-XXXXXXXXXX"; NULL if invalid.
CREATE FUNCTION fn_clean_phone(p_value VARCHAR(100))
RETURNS VARCHAR(20)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_digits VARCHAR(255) DEFAULT REGEXP_REPLACE(COALESCE(p_value, ''), '[^0-9]', '');
    IF CHAR_LENGTH(v_digits) = 12 AND LEFT(v_digits, 2) = '91' THEN
        SET v_digits = SUBSTRING(v_digits, 3);
    END IF;
    IF v_digits REGEXP '^[6-9][0-9]{9}$' THEN
        RETURN CONCAT('+91-', v_digits);
    END IF;
    RETURN NULL;
END$$

-- "FAST FOOD" / "fast food" -> "Fast Food" (after fn_clean_text).
CREATE FUNCTION fn_title_case(p_value VARCHAR(255))
RETURNS VARCHAR(255)
DETERMINISTIC NO SQL
BEGIN
    DECLARE v_text VARCHAR(255) DEFAULT LOWER(fn_clean_text(p_value));
    DECLARE v_result VARCHAR(255) DEFAULT '';
    DECLARE v_char VARCHAR(1);              -- VARCHAR, not CHAR: CHAR would drop the spaces
    DECLARE v_previous VARCHAR(1) DEFAULT ' ';
    DECLARE v_position INT DEFAULT 1;

    IF v_text IS NULL THEN
        RETURN NULL;
    END IF;
    WHILE v_position <= CHAR_LENGTH(v_text) DO
        SET v_char = SUBSTRING(v_text, v_position, 1);
        SET v_result = CONCAT(v_result, IF(v_previous IN (' ', '-', '('), UPPER(v_char), v_char));
        SET v_previous = v_char;
        SET v_position = v_position + 1;
    END WHILE;
    RETURN v_result;
END$$

DELIMITER ;
