#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 05 — Deploy Grafana Dashboards
# =============================================================================

echo "[05] Deploying Grafana dashboards..."

DASHBOARD_SRC="${SCRIPT_DIR}/grafana/dashboards"
DASHBOARD_DEST="${INFRA_DIR}/grafana/dashboards"

# Ensure destination exists
mkdir -p "${DASHBOARD_DEST}"

# Copy all dashboard JSON files
if [[ -d "${DASHBOARD_SRC}" ]]; then
  cp "${DASHBOARD_SRC}"/*.json "${DASHBOARD_DEST}/" 2>/dev/null || true
fi

# Set ownership so Grafana can read them
chown -R grafana:grafana "${DASHBOARD_DEST}" 2>/dev/null || true
chmod 644 "${DASHBOARD_DEST}"/*.json 2>/dev/null || true

# Restart Grafana to pick up new dashboards
echo "[05] Restarting Grafana to load dashboards..."
systemctl restart grafana-server

# Wait for Grafana to come back
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# List deployed dashboards
echo "[05] Deployed dashboards:"
ls -1 "${DASHBOARD_DEST}"/*.json 2>/dev/null | while read -r f; do
  name=$(jq -r '.title // .dashboard.title // "(untitled)"' "$f" 2>/dev/null)
  echo "  - ${name} ($(basename "$f"))"
done

if systemctl is-active --quiet grafana-server; then
  echo "[05] Grafana is RUNNING with dashboards loaded."
else
  echo "[05] ERROR: Grafana is NOT running."
  exit 1
fi
