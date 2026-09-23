#!/bin/sh
set -e

echo "Creating databases..."

psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" \
    --dbname postgres \
    -v platform_db="$JOB_PLATFORM_DB" \
    -v crawler_db="$JOB_CRAWLER_DB" <<'EOSQL'

CREATE DATABASE :"platform_db";
CREATE DATABASE :"crawler_db";

EOSQL

echo "Databases created successfully."