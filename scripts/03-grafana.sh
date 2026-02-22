#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 03 — Grafana OSS Install & Provisioning
# =============================================================================

echo "[03] Installing Grafana OSS..."

export DEBIAN_FRONTEND=noninteractive

apt-get install -y -qq grafana

# --- Deploy provisioning files ---
GRAFANA_PROV_DIR="/etc/grafana/provisioning"

echo "[03] Deploying dashboard provider config..."
mkdir -p "${GRAFANA_PROV_DIR}/dashboards"
cp "${SCRIPT_DIR}/grafana/provisioning/dashboards/dashboard-provider.yml" \
  "${GRAFANA_PROV_DIR}/dashboards/dashboard-provider.yml"

# Remove any old datasource provisioning files — we use the API instead
# (YAML provisioning mangles passwords containing special characters)
rm -f "${GRAFANA_PROV_DIR}/datasources/timescaledb.yml"

# --- Ensure dashboard directory exists ---
mkdir -p "${SCRIPT_DIR}/grafana/dashboards"

# --- Configure Grafana ---
GRAFANA_INI="/etc/grafana/grafana.ini"

# Set HTTP port
sed -i "s/^;*http_port = .*/http_port = ${GRAFANA_PORT}/" "${GRAFANA_INI}"

# Set admin credentials via ini (avoids grafana-cli ownership issues)
sed -i "s/^;*admin_user = .*/admin_user = ${GRAFANA_ADMIN_USER}/" "${GRAFANA_INI}"
sed -i "s/^;*admin_password = .*/admin_password = ${GRAFANA_ADMIN_PASSWORD}/" "${GRAFANA_INI}"

# Disable user signup
sed -i 's/^;*allow_sign_up = .*/allow_sign_up = false/' "${GRAFANA_INI}"

# --- Set ownership (provisioning + data dir) ---
chown -R grafana:grafana "${GRAFANA_PROV_DIR}"
chown -R grafana:grafana /var/lib/grafana

# --- Enable and restart ---
echo "[03] Restarting Grafana..."
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server

# --- Wait for Grafana to be ready ---
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# --- Create or update TimescaleDB datasource via API ---
# Using the API avoids YAML escaping issues with passwords
echo "[03] Configuring TimescaleDB datasource via API..."

GRAFANA_AUTH="${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
DS_URL="http://localhost:${GRAFANA_PORT}/api/datasources"

# Build JSON payloads using Python to avoid shell escaping issues
DS_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'TimescaleDB',
    'uid': 'timescaledb',
    'type': 'grafana-postgresql-datasource',
    'access': 'proxy',
    'url': 'localhost:${PG_PORT}',
    'database': '${PG_DB_NAME}',
    'user': '${PG_DB_USER}',
    'isDefault': True,
    'jsonData': {
        'sslmode': 'disable',
        'maxOpenConns': 10,
        'maxIdleConns': 5,
        'connMaxLifetime': 14400,
        'postgresVersion': 1500,
        'timescaledb': True,
        'authenticationType': 'password'
    },
    'secureJsonData': {
        'password': '''${PG_DB_PASSWORD}'''
    }
}))
")

PROM_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'Prometheus',
    'uid': 'prometheus',
    'type': 'prometheus',
    'access': 'proxy',
    'url': 'http://localhost:${PROMETHEUS_PORT}',
    'isDefault': False,
    'jsonData': {
        'httpMethod': 'POST',
        'timeInterval': '15s'
    }
}))
")

# Helper: delete datasource by uid if it exists, then create
create_datasource() {
  local name="$1"
  local uid="$2"
  local payload="$3"

  # Delete if exists (idempotent re-run)
  curl -sf -X DELETE "${DS_URL}/uid/${uid}" \
    -u "${GRAFANA_AUTH}" >/dev/null 2>&1 || true

  # Create
  curl -sf -X POST "${DS_URL}" \
    -u "${GRAFANA_AUTH}" \
    -H "Content-Type: application/json" \
    -d "${payload}" >/dev/null 2>&1
  echo "[03] Created datasource: ${name} (uid: ${uid})"
}

create_datasource "TimescaleDB" "timescaledb" "${DS_PAYLOAD}"
create_datasource "Prometheus" "prometheus" "${PROM_PAYLOAD}"

# Verify datasource connections
echo "[03] Verifying datasource connections..."
for ds_uid in timescaledb prometheus; do
  HEALTH=$(curl -sf "${DS_URL}/uid/${ds_uid}/health" \
    -u "${GRAFANA_AUTH}" 2>/dev/null || echo '{"status":"ERROR"}')
  STATUS=$(echo "${HEALTH}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','ERROR'))" 2>/dev/null)
  if [[ "${STATUS}" == "OK" ]]; then
    echo "[03] ${ds_uid}: connected."
  else
    echo "[03] WARNING: ${ds_uid} connection test failed: ${HEALTH}"
  fi
done

if systemctl is-active --quiet grafana-server; then
  echo "[03] Grafana is RUNNING on port ${GRAFANA_PORT}."
else
  echo "[03] ERROR: Grafana is NOT running."
  exit 1
fi
