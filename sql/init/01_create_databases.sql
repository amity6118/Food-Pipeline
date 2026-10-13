-- ============================================================================
-- 01_create_databases.sql
-- Description: Creates the staging, control and warehouse databases.
-- Application users (ETL + Power BI read-only) are created by
-- 99_create_app_users.sh, because plain .sql init scripts cannot read
-- credentials from environment variables.
-- ============================================================================

CREATE DATABASE IF NOT EXISTS food_staging
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS food_control
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS food_dw
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;
