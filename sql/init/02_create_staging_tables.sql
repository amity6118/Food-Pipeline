-- ============================================================================
-- 02_create_staging_tables.sql
-- Description: Raw staging tables with loose VARCHAR types and audit metadata
-- Architecture Rule: Staging strictly preserves raw source representation
-- ============================================================================

USE food_staging;

-- ----------------------------------------------------------------------------
-- 1. Raw Customers Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_customers;
CREATE TABLE stg_customers (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    customer_id VARCHAR(100),
    customer_name VARCHAR(255),
    email VARCHAR(255),
    phone VARCHAR(100),
    city VARCHAR(100),
    state VARCHAR(100),
    pincode VARCHAR(50),
    signup_date VARCHAR(100),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_cust_batch (batch_id),
    INDEX idx_stg_cust_id (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 2. Raw Restaurants Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_restaurants;
CREATE TABLE stg_restaurants (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    restaurant_id VARCHAR(100),
    name VARCHAR(255),
    cuisine_type VARCHAR(100),
    city VARCHAR(100),
    area VARCHAR(100),
    rating VARCHAR(50),
    cost_for_two VARCHAR(50),
    is_active_partner VARCHAR(50),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_rest_batch (batch_id),
    INDEX idx_stg_rest_id (restaurant_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 3. Raw Menu Items Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_menu_items;
CREATE TABLE stg_menu_items (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    item_id VARCHAR(100),
    restaurant_id VARCHAR(100),
    item_name VARCHAR(255),
    category VARCHAR(100),
    is_veg VARCHAR(50),
    base_price VARCHAR(50),
    is_available VARCHAR(50),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_item_batch (batch_id),
    INDEX idx_stg_item_id (item_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 4. Raw Delivery Partners Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_delivery_partners;
CREATE TABLE stg_delivery_partners (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    partner_id VARCHAR(100),
    partner_name VARCHAR(255),
    phone VARCHAR(100),
    vehicle_type VARCHAR(100),
    city VARCHAR(100),
    rating VARCHAR(50),
    status VARCHAR(50),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_part_batch (batch_id),
    INDEX idx_stg_part_id (partner_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 5. Raw Orders Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_orders;
CREATE TABLE stg_orders (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id VARCHAR(100),
    customer_id VARCHAR(100),
    restaurant_id VARCHAR(100),
    delivery_partner_id VARCHAR(100),
    payment_method_id VARCHAR(100),
    order_datetime VARCHAR(100),
    gross_amount VARCHAR(50),
    discount VARCHAR(50),
    delivery_fee VARCHAR(50),
    net_amount VARCHAR(50),
    delivery_minutes VARCHAR(50),
    rating VARCHAR(50),
    order_status VARCHAR(100),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_ord_batch (batch_id),
    INDEX idx_stg_ord_id (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 6. Raw Order Items Staging
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_order_items;
CREATE TABLE stg_order_items (
    stg_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    order_id VARCHAR(100),
    item_id VARCHAR(100),
    quantity VARCHAR(50),
    unit_price VARCHAR(50),
    batch_id VARCHAR(64) NOT NULL,
    source_file VARCHAR(255) NOT NULL,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_stg_items_batch (batch_id),
    INDEX idx_stg_items_ord (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 7. Staging Rejected Records (Dead Letter Storage for Cleansing Errors)
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_rejected_records;
CREATE TABLE stg_rejected_records (
    rejection_id BIGINT AUTO_INCREMENT PRIMARY KEY,
    batch_id VARCHAR(64) NOT NULL,
    source_table VARCHAR(100) NOT NULL,
    record_identifier VARCHAR(100),
    raw_payload JSON,
    rejection_reason VARCHAR(255) NOT NULL,
    rejected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_rej_batch (batch_id),
    INDEX idx_rej_table (source_table)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
