-- ============================================================================
-- 04_create_dw_tables.sql
-- Description: Star schema tables, foreign keys, and indexes for food_dw
-- ============================================================================

USE food_dw;

-- ----------------------------------------------------------------------------
-- 1. Date Dimension
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_date;
CREATE TABLE dim_date (
    date_key INT PRIMARY KEY COMMENT 'Format YYYYMMDD',
    full_date DATE NOT NULL UNIQUE,
    year SMALLINT NOT NULL,
    quarter TINYINT NOT NULL,
    month TINYINT NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    day TINYINT NOT NULL,
    day_name VARCHAR(20) NOT NULL,
    day_of_week TINYINT NOT NULL COMMENT '1=Sunday, 7=Saturday',
    is_weekend TINYINT(1) NOT NULL,
    is_holiday TINYINT(1) NOT NULL,
    holiday_name VARCHAR(100) NULL,
    INDEX idx_date_full (full_date),
    INDEX idx_date_year_month (year, month)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 2. Customer Dimension (SCD Type 2)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_customer;
CREATE TABLE dim_customer (
    customer_key INT AUTO_INCREMENT PRIMARY KEY,
    customer_id VARCHAR(50) NOT NULL,
    customer_name VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(100) NOT NULL,
    pincode VARCHAR(20) NOT NULL,
    signup_date DATE NOT NULL,
    scd_version INT NOT NULL DEFAULT 1,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    valid_from DATETIME NOT NULL,
    valid_to DATETIME NOT NULL DEFAULT '9999-12-31 23:59:59',
    INDEX idx_cust_nk (customer_id),
    INDEX idx_cust_lookup (customer_id, is_active),
    INDEX idx_cust_city (city)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 3. Restaurant Dimension (SCD Type 2)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_restaurant;
CREATE TABLE dim_restaurant (
    restaurant_key INT AUTO_INCREMENT PRIMARY KEY,
    restaurant_id VARCHAR(50) NOT NULL,
    name VARCHAR(255) NOT NULL,
    cuisine_type VARCHAR(100) NOT NULL,
    city VARCHAR(100) NOT NULL,
    area VARCHAR(100) NOT NULL,
    rating DECIMAL(2,1) NOT NULL DEFAULT 0.0,
    cost_for_two DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    is_active_partner TINYINT(1) NOT NULL DEFAULT 1,
    scd_version INT NOT NULL DEFAULT 1,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    valid_from DATETIME NOT NULL,
    valid_to DATETIME NOT NULL DEFAULT '9999-12-31 23:59:59',
    INDEX idx_rest_nk (restaurant_id),
    INDEX idx_rest_lookup (restaurant_id, is_active),
    INDEX idx_rest_city_cuisine (city, cuisine_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 4. Menu Item Dimension
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_menu_item;
CREATE TABLE dim_menu_item (
    menu_item_key INT AUTO_INCREMENT PRIMARY KEY,
    item_id VARCHAR(50) NOT NULL UNIQUE,
    restaurant_id VARCHAR(50) NOT NULL,
    item_name VARCHAR(255) NOT NULL,
    category VARCHAR(100) NOT NULL,
    is_veg TINYINT(1) NOT NULL DEFAULT 1,
    base_price DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    is_available TINYINT(1) NOT NULL DEFAULT 1,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_menu_item_nk (item_id),
    INDEX idx_menu_item_rest (restaurant_id),
    INDEX idx_menu_item_cat (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 5. Delivery Partner Dimension
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_delivery_partner;
CREATE TABLE dim_delivery_partner (
    delivery_partner_key INT AUTO_INCREMENT PRIMARY KEY,
    partner_id VARCHAR(50) NOT NULL UNIQUE,
    partner_name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    vehicle_type VARCHAR(50) NOT NULL,
    city VARCHAR(100) NOT NULL,
    rating DECIMAL(2,1) NOT NULL DEFAULT 0.0,
    status VARCHAR(50) NOT NULL DEFAULT 'ACTIVE',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_part_nk (partner_id),
    INDEX idx_part_city (city)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 6. Payment Method Dimension
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_payment_method;
CREATE TABLE dim_payment_method (
    payment_method_key INT AUTO_INCREMENT PRIMARY KEY,
    payment_method_id VARCHAR(50) NOT NULL UNIQUE,
    method_name VARCHAR(100) NOT NULL,
    method_category VARCHAR(50) NOT NULL COMMENT 'UPI, CARD, NETBANKING, COD, WALLET',
    INDEX idx_pm_nk (payment_method_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 7. Fact Orders (Grain: One row per customer order)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS fact_orders;
CREATE TABLE fact_orders (
    order_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id VARCHAR(50) NOT NULL UNIQUE,
    date_key INT NOT NULL,
    customer_key INT NOT NULL,
    restaurant_key INT NOT NULL,
    delivery_partner_key INT NOT NULL,
    payment_method_key INT NOT NULL,
    order_datetime DATETIME NOT NULL,
    gross_amount DECIMAL(10,2) NOT NULL,
    discount DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    delivery_fee DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    net_amount DECIMAL(10,2) NOT NULL,
    delivery_minutes INT NOT NULL DEFAULT 0,
    is_late TINYINT(1) NOT NULL DEFAULT 0,
    rating DECIMAL(2,1) NULL,
    order_status VARCHAR(50) NOT NULL,
    batch_id VARCHAR(64) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Foreign Key Constraints
    CONSTRAINT fk_fact_orders_date
        FOREIGN KEY (date_key) REFERENCES dim_date (date_key),
    CONSTRAINT fk_fact_orders_customer
        FOREIGN KEY (customer_key) REFERENCES dim_customer (customer_key),
    CONSTRAINT fk_fact_orders_restaurant
        FOREIGN KEY (restaurant_key) REFERENCES dim_restaurant (restaurant_key),
    CONSTRAINT fk_fact_orders_delivery_partner
        FOREIGN KEY (delivery_partner_key) REFERENCES dim_delivery_partner (delivery_partner_key),
    CONSTRAINT fk_fact_orders_payment_method
        FOREIGN KEY (payment_method_key) REFERENCES dim_payment_method (payment_method_key),
        
    -- Indexes for Power BI Filter & Slicing Performance
    INDEX idx_ord_dt (order_datetime),
    INDEX idx_ord_date_key (date_key),
    INDEX idx_ord_cust_key (customer_key),
    INDEX idx_ord_rest_key (restaurant_key),
    INDEX idx_ord_partner_key (delivery_partner_key),
    INDEX idx_ord_pm_key (payment_method_key),
    INDEX idx_ord_batch (batch_id),
    INDEX idx_ord_status (order_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 8. Fact Order Items (Grain: One row per item per order)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS fact_order_items;
CREATE TABLE fact_order_items (
    order_item_key BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_key BIGINT NOT NULL,
    menu_item_key INT NOT NULL,
    quantity INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    line_total DECIMAL(10,2) NOT NULL,
    batch_id VARCHAR(64) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Foreign Key Constraints
    CONSTRAINT fk_fact_items_order
        FOREIGN KEY (order_key) REFERENCES fact_orders (order_key) ON DELETE CASCADE,
    CONSTRAINT fk_fact_items_menu
        FOREIGN KEY (menu_item_key) REFERENCES dim_menu_item (menu_item_key),
        
    -- Indexes
    INDEX idx_item_order_key (order_key),
    INDEX idx_item_menu_key (menu_item_key),
    INDEX idx_item_batch (batch_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
