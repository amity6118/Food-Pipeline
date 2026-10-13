#!/bin/bash
# ============================================================================
# 10_create_app_users.sh
# Description: Creates the ETL service account and the Power BI read-only user
# with credentials taken from environment variables (.env), so no password is
# ever stored in the repository.
# Runs once, on first MySQL container boot, via /docker-entrypoint-initdb.d.
# ============================================================================

: "${MYSQL_USER:?MYSQL_USER must be set in .env}"
: "${MYSQL_PASSWORD:?MYSQL_PASSWORD must be set in .env}"
: "${POWERBI_USER:?POWERBI_USER must be set in .env}"
: "${POWERBI_PASSWORD:?POWERBI_PASSWORD must be set in .env}"

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOSQL
-- ETL service account: full DDL/DML rights on the three pipeline databases.
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%'
    IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON food_staging.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON food_control.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON food_dw.*      TO '${MYSQL_USER}'@'%';

-- Power BI reporting user: SELECT only on the warehouse and control databases.
-- Raw staging data is deliberately not exposed to reporting.
CREATE USER IF NOT EXISTS '${POWERBI_USER}'@'%'
    IDENTIFIED WITH mysql_native_password BY '${POWERBI_PASSWORD}';
GRANT SELECT ON food_dw.*      TO '${POWERBI_USER}'@'%';
GRANT SELECT ON food_control.* TO '${POWERBI_USER}'@'%';

FLUSH PRIVILEGES;
EOSQL
