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

echo "[03] Deploying datasource provisioning..."
mkdir -p "${GRAFANA_PROV_DIR}/datasources"
envsubst < "${SCRIPT_DIR}/grafana/provisioning/datasources/timescaledb.yml" \
  > "${GRAFANA_PROV_DIR}/datasources/timescaledb.yml"

echo "[03] Deploying dashboard provider config..."
mkdir -p "${GRAFANA_PROV_DIR}/dashboards"
cp "${SCRIPT_DIR}/grafana/provisioning/dashboards/dashboard-provider.yml" \
  "${GRAFANA_PROV_DIR}/dashboards/dashboard-provider.yml"

# --- Ensure dashboard directory exists ---
mkdir -p "${SCRIPT_DIR}/grafana/dashboards"

# --- Configure Grafana ---
GRAFANA_INI="/etc/grafana/grafana.ini"

# Set HTTP port
sed -i "s/^;*http_port = .*/http_port = ${GRAFANA_PORT}/" "${GRAFANA_INI}"

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

# --- Set admin password via API (works on first run and re-runs) ---
echo "[03] Setting admin password..."
# Try changing from default first, then try with current password (idempotent re-run)
curl -sf -X PUT \
  "http://admin:admin@localhost:${GRAFANA_PORT}/api/user/password" \
  -H "Content-Type: application/json" \
  -d "{\"oldPassword\":\"admin\",\"newPassword\":\"${GRAFANA_ADMIN_PASSWORD}\"}" \
  2>/dev/null || \
curl -sf -X PUT \
  "http://admin:${GRAFANA_ADMIN_PASSWORD}@localhost:${GRAFANA_PORT}/api/user/password" \
  -H "Content-Type: application/json" \
  -d "{\"oldPassword\":\"${GRAFANA_ADMIN_PASSWORD}\",\"newPassword\":\"${GRAFANA_ADMIN_PASSWORD}\"}" \
  2>/dev/null || true

if systemctl is-active --quiet grafana-server; then
  echo "[03] Grafana is RUNNING on port ${GRAFANA_PORT}."
else
  echo "[03] ERROR: Grafana is NOT running."
  exit 1
fi
