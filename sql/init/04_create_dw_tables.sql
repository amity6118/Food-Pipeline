-- ============================================================================
-- 04_create_dw_tables.sql
-- Star schema in food_dw.
--
--   fact_orders       grain: one row per order            (natural key order_id)
--   fact_order_items  grain: one row per item per order   (order_key, menu_item_key)
--   dim_customer, dim_restaurant           SCD Type 2 (full history)
--   dim_menu_item, dim_delivery_partner,
--   dim_payment_method                     SCD Type 1 (overwrite)
--   dim_date                               calendar, populated by 06_create_dim_date.sql
--
-- Unique keys on every natural key / grain make the procedures' upserts
-- idempotent: re-running a batch updates rows instead of duplicating them.
-- ============================================================================

USE food_dw;

-- ----------------------------------------------------------------------------
-- Date dimension
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_date (
    date_key      INT          PRIMARY KEY COMMENT 'YYYYMMDD',
    full_date     DATE         NOT NULL,
    year          SMALLINT     NOT NULL,
    quarter       TINYINT      NOT NULL,
    quarter_name  CHAR(2)      NOT NULL COMMENT 'Q1..Q4',
    month         TINYINT      NOT NULL,
    month_name    VARCHAR(10)  NOT NULL,
    month_short   CHAR(3)      NOT NULL,
    month_label   CHAR(7)      NOT NULL COMMENT 'YYYY-MM, sorts chronologically',
    week_of_year  TINYINT      NOT NULL COMMENT 'ISO week number',
    day_of_month  TINYINT      NOT NULL,
    day_of_week   TINYINT      NOT NULL COMMENT '1 = Monday ... 7 = Sunday (ISO)',
    day_name      VARCHAR(10)  NOT NULL,
    day_short     CHAR(3)      NOT NULL,
    is_weekend    TINYINT(1)   NOT NULL,
    is_holiday    TINYINT(1)   NOT NULL COMMENT 'Indian national holiday',
    is_festival   TINYINT(1)   NOT NULL COMMENT 'Major festival / high-demand day',
    holiday_name  VARCHAR(150) NULL,
    UNIQUE KEY uq_dim_date_full_date (full_date),
    INDEX idx_dim_date_year_month (year, month)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Customer dimension (SCD Type 2)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key        INT AUTO_INCREMENT PRIMARY KEY,
    customer_id         VARCHAR(50)  NOT NULL COMMENT 'Natural key from the source system',
    customer_name       VARCHAR(255) NOT NULL,
    email               VARCHAR(255) NULL,
    phone               VARCHAR(20)  NULL,
    city                VARCHAR(100) NOT NULL,
    state               VARCHAR(100) NOT NULL,
    pincode             CHAR(6)      NULL,
    signup_date         DATE         NULL,
    -- SCD Type 2 tracking
    row_hash            CHAR(32)     NOT NULL COMMENT 'MD5 of tracked attributes; a change creates a new version',
    scd_version         INT          NOT NULL DEFAULT 1,
    valid_from          DATETIME     NOT NULL,
    valid_to            DATETIME     NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current          TINYINT(1)   NOT NULL DEFAULT 1,
    current_customer_id VARCHAR(50)  GENERATED ALWAYS AS (IF(is_current = 1, customer_id, NULL)) STORED
                        COMMENT 'Unique index on this enforces one current row per customer',
    -- Lineage
    batch_id            VARCHAR(64)  NOT NULL,
    dw_created_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_customer_version (customer_id, scd_version),
    UNIQUE KEY uq_dim_customer_current (current_customer_id),
    INDEX idx_dim_customer_validity (customer_id, valid_from, valid_to),
    INDEX idx_dim_customer_city (city)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Restaurant dimension (SCD Type 2)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_restaurant (
    restaurant_key        INT AUTO_INCREMENT PRIMARY KEY,
    restaurant_id         VARCHAR(50)   NOT NULL COMMENT 'Natural key from the source system',
    restaurant_name       VARCHAR(255)  NOT NULL,
    cuisine_type          VARCHAR(100)  NOT NULL,
    city                  VARCHAR(100)  NOT NULL,
    area                  VARCHAR(100)  NOT NULL,
    rating                DECIMAL(2,1)  NULL,
    cost_for_two          DECIMAL(10,2) NULL,
    is_active_partner     TINYINT(1)    NOT NULL DEFAULT 1,
    -- SCD Type 2 tracking
    row_hash              CHAR(32)      NOT NULL COMMENT 'MD5 of tracked attributes; a change creates a new version',
    scd_version           INT           NOT NULL DEFAULT 1,
    valid_from            DATETIME      NOT NULL,
    valid_to              DATETIME      NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current            TINYINT(1)    NOT NULL DEFAULT 1,
    current_restaurant_id VARCHAR(50)   GENERATED ALWAYS AS (IF(is_current = 1, restaurant_id, NULL)) STORED
                          COMMENT 'Unique index on this enforces one current row per restaurant',
    -- Lineage
    batch_id              VARCHAR(64)   NOT NULL,
    dw_created_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_restaurant_version (restaurant_id, scd_version),
    UNIQUE KEY uq_dim_restaurant_current (current_restaurant_id),
    INDEX idx_dim_restaurant_validity (restaurant_id, valid_from, valid_to),
    INDEX idx_dim_restaurant_city_cuisine (city, cuisine_type)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Menu item dimension (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_menu_item (
    menu_item_key   INT AUTO_INCREMENT PRIMARY KEY,
    item_id         VARCHAR(50)   NOT NULL COMMENT 'Natural key from the source system',
    restaurant_id   VARCHAR(50)   NOT NULL COMMENT 'Owning restaurant (natural key)',
    item_name       VARCHAR(255)  NOT NULL,
    category        VARCHAR(100)  NOT NULL,
    is_veg          TINYINT(1)    NOT NULL,
    base_price      DECIMAL(10,2) NOT NULL,
    is_available    TINYINT(1)    NOT NULL DEFAULT 1,
    batch_id        VARCHAR(64)   NOT NULL,
    dw_created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_menu_item_nk (item_id),
    INDEX idx_dim_menu_item_restaurant (restaurant_id),
    INDEX idx_dim_menu_item_category (category)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Delivery partner dimension (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_delivery_partner (
    delivery_partner_key INT AUTO_INCREMENT PRIMARY KEY,
    partner_id           VARCHAR(50)  NOT NULL COMMENT 'Natural key from the source system',
    partner_name         VARCHAR(255) NOT NULL,
    phone                VARCHAR(20)  NULL,
    vehicle_type         VARCHAR(50)  NOT NULL,
    city                 VARCHAR(100) NOT NULL,
    rating               DECIMAL(2,1) NULL,
    status               VARCHAR(20)  NOT NULL,
    batch_id             VARCHAR(64)  NOT NULL,
    dw_created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_delivery_partner_nk (partner_id),
    INDEX idx_dim_delivery_partner_city (city)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Payment method dimension (SCD Type 1)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_payment_method (
    payment_method_key INT AUTO_INCREMENT PRIMARY KEY,
    payment_method_id  VARCHAR(50)  NOT NULL COMMENT 'Natural key from the source system',
    method_name        VARCHAR(100) NOT NULL,
    method_category    VARCHAR(20)  NOT NULL COMMENT 'UPI, CARD, NETBANKING, COD, WALLET',
    batch_id           VARCHAR(64)  NOT NULL,
    dw_created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_dim_payment_method_nk (payment_method_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Fact: orders (grain = one row per order)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_orders (
    order_key            BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id             VARCHAR(50)   NOT NULL COMMENT 'Natural key; upsert target',
    date_key             INT           NOT NULL,
    customer_key         INT           NOT NULL COMMENT 'Customer version valid at order time',
    restaurant_key       INT           NOT NULL COMMENT 'Restaurant version valid at order time',
    delivery_partner_key INT           NOT NULL,
    payment_method_key   INT           NOT NULL,
    order_datetime       DATETIME      NOT NULL,
    gross_amount         DECIMAL(10,2) NOT NULL,
    discount             DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    delivery_fee         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    net_amount           DECIMAL(10,2) NOT NULL COMMENT 'gross_amount - discount + delivery_fee',
    delivery_minutes     SMALLINT      NULL     COMMENT 'NULL for cancelled orders',
    is_late              TINYINT(1)    NOT NULL DEFAULT 0 COMMENT '1 when delivery exceeded the SLA',
    rating               DECIMAL(2,1)  NULL,
    order_status         ENUM('DELIVERED', 'CANCELLED', 'REFUNDED') NOT NULL,
    batch_id             VARCHAR(64)   NOT NULL,
    dw_created_at        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    UNIQUE KEY uq_fact_orders_order_id (order_id),

    -- Safety net behind the procedures' cleansing: bad rows are rejected before
    -- they reach this table, so these should never fire.
    CONSTRAINT chk_fact_orders_amounts
        CHECK (gross_amount > 0 AND discount >= 0 AND discount <= gross_amount AND delivery_fee >= 0),
    CONSTRAINT chk_fact_orders_rating
        CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),

    CONSTRAINT fk_fact_orders_date             FOREIGN KEY (date_key)             REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_orders_customer         FOREIGN KEY (customer_key)         REFERENCES dim_customer (customer_key),
    CONSTRAINT fk_fact_orders_restaurant       FOREIGN KEY (restaurant_key)       REFERENCES dim_restaurant (restaurant_key),
    CONSTRAINT fk_fact_orders_delivery_partner FOREIGN KEY (delivery_partner_key) REFERENCES dim_delivery_partner (delivery_partner_key),
    CONSTRAINT fk_fact_orders_payment_method   FOREIGN KEY (payment_method_key)   REFERENCES dim_payment_method (payment_method_key),

    -- Every foreign key indexed for join / slicer performance
    INDEX idx_fact_orders_date_key (date_key),
    INDEX idx_fact_orders_customer_key (customer_key),
    INDEX idx_fact_orders_restaurant_key (restaurant_key),
    INDEX idx_fact_orders_delivery_partner_key (delivery_partner_key),
    INDEX idx_fact_orders_payment_method_key (payment_method_key),
    INDEX idx_fact_orders_order_datetime (order_datetime),
    INDEX idx_fact_orders_status (order_status),
    INDEX idx_fact_orders_batch (batch_id)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Fact: order items (grain = one row per menu item per order)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_order_items (
    order_item_key  BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_key       BIGINT        NOT NULL,
    menu_item_key   INT           NOT NULL,
    quantity        SMALLINT      NOT NULL,
    unit_price      DECIMAL(10,2) NOT NULL,
    line_total      DECIMAL(10,2) NOT NULL COMMENT 'quantity * unit_price',
    batch_id        VARCHAR(64)   NOT NULL,
    dw_created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    dw_updated_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

    -- Grain key; its leading column also serves as the order_key foreign-key index
    UNIQUE KEY uq_fact_order_items_grain (order_key, menu_item_key),

    CONSTRAINT chk_fact_order_items_values CHECK (quantity > 0 AND unit_price >= 0),

    CONSTRAINT fk_fact_order_items_order FOREIGN KEY (order_key)     REFERENCES fact_orders (order_key) ON DELETE CASCADE,
    CONSTRAINT fk_fact_order_items_menu  FOREIGN KEY (menu_item_key) REFERENCES dim_menu_item (menu_item_key),

    INDEX idx_fact_order_items_menu_item_key (menu_item_key),
    INDEX idx_fact_order_items_batch (batch_id)
) ENGINE=InnoDB;
