#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 02 — PostgreSQL + TimescaleDB Install & Configuration
# =============================================================================

echo "[02] Installing PostgreSQL and TimescaleDB..."

export DEBIAN_FRONTEND=noninteractive

# --- Detect PostgreSQL major version available ---
PG_MAJOR=$(apt-cache show postgresql | grep -oP 'Version: \K[0-9]+' | head -1)
echo "[02] Detected PostgreSQL major version: ${PG_MAJOR}"

apt-get install -y -qq \
  "postgresql-${PG_MAJOR}" \
  "postgresql-client-${PG_MAJOR}" \
  "timescaledb-2-postgresql-${PG_MAJOR}"

PG_CONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_DATA_DIR="/var/lib/postgresql/${PG_MAJOR}/main"

# --- Run timescaledb-tune non-interactively ---
echo "[02] Running timescaledb-tune..."
timescaledb-tune --quiet --yes --pg-config "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" || true

# --- Generate memory-aware postgresql.conf ---
echo "[02] Deploying tuned postgresql.conf..."

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

# shared_buffers: 25% of RAM
export PG_SHARED_BUFFERS="$((TOTAL_RAM_MB / 4))MB"
# effective_cache_size: 75% of RAM
export PG_EFFECTIVE_CACHE_SIZE="$((TOTAL_RAM_MB * 3 / 4))MB"
# work_mem: RAM / max_connections / 4 (conservative)
export PG_WORK_MEM="$((TOTAL_RAM_MB / 400))MB"
# maintenance_work_mem: 5% of RAM, max 2GB
MAINT_MEM=$((TOTAL_RAM_MB / 20))
if [[ ${MAINT_MEM} -gt 2048 ]]; then MAINT_MEM=2048; fi
export PG_MAINTENANCE_WORK_MEM="${MAINT_MEM}MB"
# WAL buffers
export PG_WAL_BUFFERS="64MB"
export PG_PORT="${PG_PORT}"
export PG_MAJOR="${PG_MAJOR}"

envsubst < "${SCRIPT_DIR}/config/postgresql.conf.tmpl" > "${PG_CONF_DIR}/postgresql.conf"

# --- Deploy pg_hba.conf ---
echo "[02] Deploying pg_hba.conf..."
cp "${SCRIPT_DIR}/config/pg_hba.conf" "${PG_CONF_DIR}/pg_hba.conf"
chown postgres:postgres "${PG_CONF_DIR}/pg_hba.conf"
chmod 640 "${PG_CONF_DIR}/pg_hba.conf"

# --- Ensure correct ownership on postgresql.conf ---
chown postgres:postgres "${PG_CONF_DIR}/postgresql.conf"
chmod 644 "${PG_CONF_DIR}/postgresql.conf"

# --- Restart PostgreSQL to apply config ---
echo "[02] Restarting PostgreSQL..."
systemctl restart postgresql
systemctl enable postgresql

# --- Wait for PostgreSQL to be ready ---
for i in $(seq 1 30); do
  if sudo -u postgres pg_isready -q 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! sudo -u postgres pg_isready -q 2>/dev/null; then
  echo "ERROR: PostgreSQL failed to start"
  exit 1
fi

# --- Create database and service account ---
echo "[02] Creating database '${PG_DB_NAME}' and user '${PG_DB_USER}'..."

sudo -u postgres psql -v ON_ERROR_STOP=0 <<EOSQL
-- Create role if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${PG_DB_USER}') THEN
    CREATE ROLE ${PG_DB_USER} WITH LOGIN PASSWORD '${PG_DB_PASSWORD}';
  END IF;
END
\$\$;

-- Always reset password to ensure hash matches current password_encryption setting
ALTER ROLE ${PG_DB_USER} WITH PASSWORD '${PG_DB_PASSWORD}';

-- Create database if not exists
SELECT 'CREATE DATABASE ${PG_DB_NAME} OWNER ${PG_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${PG_DB_NAME}')\gexec

-- Ensure ownership
ALTER DATABASE ${PG_DB_NAME} OWNER TO ${PG_DB_USER};
EOSQL

# --- Enable TimescaleDB extension in the analytics database ---
echo "[02] Enabling TimescaleDB extension..."
sudo -u postgres psql -d "${PG_DB_NAME}" -v ON_ERROR_STOP=0 <<EOSQL
CREATE EXTENSION IF NOT EXISTS timescaledb;
EOSQL

# --- Grant scoped permissions ---
sudo -u postgres psql -d "${PG_DB_NAME}" -v ON_ERROR_STOP=0 <<EOSQL
GRANT CONNECT ON DATABASE ${PG_DB_NAME} TO ${PG_DB_USER};
GRANT USAGE ON SCHEMA public TO ${PG_DB_USER};
GRANT CREATE ON SCHEMA public TO ${PG_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PG_DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${PG_DB_USER};
EOSQL

# --- Verify ---
echo "[02] Verifying TimescaleDB..."
sudo -u postgres psql -d "${PG_DB_NAME}" -c "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';"

if systemctl is-active --quiet postgresql; then
  echo "[02] PostgreSQL + TimescaleDB is RUNNING."
else
  echo "[02] ERROR: PostgreSQL is NOT running."
  exit 1
fi
