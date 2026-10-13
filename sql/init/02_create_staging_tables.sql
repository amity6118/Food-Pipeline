-- ============================================================================
-- 02_create_staging_tables.sql
-- Raw landing tables in food_staging.
--
-- Design rules
--   * Business columns are loose VARCHARs, so a malformed source value never
--     breaks the bulk load. Typing and cleansing happen in the stored procedures.
--   * Every row carries audit columns: batch_id, source_file, loaded_at.
--   * stg_id only ever increases, so the warehouse procedures use it as their
--     incremental watermark (rows with stg_id > last processed stg_id).
--   * Staging keeps every batch for auditing; re-ingesting a batch first deletes
--     that batch's rows, which keeps reloads idempotent.
-- ============================================================================

USE food_staging;

-- ----------------------------------------------------------------------------
-- Master data (CSV files)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_customers (
    stg_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    customer_id     VARCHAR(100),
    customer_name   VARCHAR(255),
    email           VARCHAR(255),
    phone           VARCHAR(100),
    city            VARCHAR(100),
    state           VARCHAR(100),
    pincode         VARCHAR(50),
    signup_date     VARCHAR(100),
    batch_id        VARCHAR(64)  NOT NULL,
    source_file     VARCHAR(255) NOT NULL,
    loaded_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_customers_batch (batch_id),
    INDEX idx_stg_customers_nk (customer_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_restaurants (
    stg_id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    restaurant_id     VARCHAR(100),
    name              VARCHAR(255),
    cuisine_type      VARCHAR(100),
    city              VARCHAR(100),
    area              VARCHAR(100),
    rating            VARCHAR(50),
    cost_for_two      VARCHAR(50),
    is_active_partner VARCHAR(50),
    batch_id          VARCHAR(64)  NOT NULL,
    source_file       VARCHAR(255) NOT NULL,
    loaded_at         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_restaurants_batch (batch_id),
    INDEX idx_stg_restaurants_nk (restaurant_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_menu_items (
    stg_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    item_id         VARCHAR(100),
    restaurant_id   VARCHAR(100),
    item_name       VARCHAR(255),
    category        VARCHAR(100),
    is_veg          VARCHAR(50),
    base_price      VARCHAR(50),
    is_available    VARCHAR(50),
    batch_id        VARCHAR(64)  NOT NULL,
    source_file     VARCHAR(255) NOT NULL,
    loaded_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_menu_items_batch (batch_id),
    INDEX idx_stg_menu_items_nk (item_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_delivery_partners (
    stg_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    partner_id      VARCHAR(100),
    partner_name    VARCHAR(255),
    phone           VARCHAR(100),
    vehicle_type    VARCHAR(100),
    city            VARCHAR(100),
    rating          VARCHAR(50),
    status          VARCHAR(50),
    batch_id        VARCHAR(64)  NOT NULL,
    source_file     VARCHAR(255) NOT NULL,
    loaded_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_delivery_partners_batch (batch_id),
    INDEX idx_stg_delivery_partners_nk (partner_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_payment_methods (
    stg_id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    payment_method_id VARCHAR(100),
    method_name       VARCHAR(100),
    method_category   VARCHAR(100),
    batch_id          VARCHAR(64)  NOT NULL,
    source_file       VARCHAR(255) NOT NULL,
    loaded_at         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_payment_methods_batch (batch_id),
    INDEX idx_stg_payment_methods_nk (payment_method_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Transactions (mock API JSON, flattened into orders + order items)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_orders (
    stg_id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id            VARCHAR(100),
    customer_id         VARCHAR(100),
    restaurant_id       VARCHAR(100),
    delivery_partner_id VARCHAR(100),
    payment_method_id   VARCHAR(100),
    order_datetime      VARCHAR(100),
    gross_amount        VARCHAR(50),
    discount            VARCHAR(50),
    delivery_fee        VARCHAR(50),
    net_amount          VARCHAR(50),
    delivery_minutes    VARCHAR(50),
    rating              VARCHAR(50),
    order_status        VARCHAR(100),
    batch_id            VARCHAR(64)  NOT NULL,
    source_file         VARCHAR(255) NOT NULL,
    loaded_at           DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_orders_batch (batch_id),
    INDEX idx_stg_orders_nk (order_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS stg_order_items (
    stg_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id        VARCHAR(100),
    item_id         VARCHAR(100),
    quantity        VARCHAR(50),
    unit_price      VARCHAR(50),
    batch_id        VARCHAR(64)  NOT NULL,
    source_file     VARCHAR(255) NOT NULL,
    loaded_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_order_items_batch (batch_id),
    INDEX idx_stg_order_items_order (order_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Rejected records: rows the procedures could not load, with the reason
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_rejected_records (
    rejection_id      BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id          VARCHAR(64)  NOT NULL,
    source_table      VARCHAR(100) NOT NULL,
    stg_id            BIGINT       NULL COMMENT 'stg_id of the rejected row in source_table',
    record_identifier VARCHAR(100) NULL COMMENT 'Natural key of the rejected row, when present',
    rejection_reason  VARCHAR(255) NOT NULL,
    rejected_by       VARCHAR(100) NOT NULL COMMENT 'Procedure that rejected the row',
    raw_payload       JSON         NULL     COMMENT 'Original staging row',
    rejected_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_rejected_batch_table (batch_id, source_table),
    INDEX idx_rejected_reason (rejection_reason)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Column profile per batch: completeness and cardinality of each staging column
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_column_profile (
    profile_id      BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id        VARCHAR(64)  NOT NULL,
    table_name      VARCHAR(64)  NOT NULL,
    column_name     VARCHAR(64)  NOT NULL,
    row_count       INT          NOT NULL,
    blank_count     INT          NOT NULL COMMENT 'NULL or whitespace-only values',
    distinct_count  INT          NOT NULL,
    min_value       VARCHAR(255) NULL,
    max_value       VARCHAR(255) NULL,
    profiled_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_profile_batch_column (batch_id, table_name, column_name)
) ENGINE=InnoDB;
