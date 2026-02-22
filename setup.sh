#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Infra Stack — Single Entrypoint
# Run: sudo ./setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Require root ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo ./setup.sh)"
  exit 1
fi

# --- Load config ---
if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
  echo "ERROR: .env file not found. Copy .env.example to .env and edit it first."
  echo "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/.env"
set +a

export SCRIPT_DIR

# --- Validate required vars ---
REQUIRED_VARS=(
  PG_DB_NAME PG_DB_USER PG_DB_PASSWORD PG_PORT
  GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_PORT
  PROMETHEUS_PORT NODE_EXPORTER_PORT SSH_PORT INFRA_DIR
)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required variable ${var} is not set in .env"
    exit 1
  fi
done

# --- Warn on default passwords ---
if [[ "${PG_DB_PASSWORD}" == "CHANGE_ME_STRONG_PASSWORD" ]] || \
   [[ "${GRAFANA_ADMIN_PASSWORD}" == "CHANGE_ME_GRAFANA_PASSWORD" ]]; then
  echo "WARNING: You are using default passwords from .env.example."
  echo "         This is insecure. Edit .env before deploying to production."
  echo ""
  read -r -p "Continue anyway? [y/N] " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    exit 1
  fi
fi

# --- Install repo to INFRA_DIR if not already there ---
if [[ "${SCRIPT_DIR}" != "${INFRA_DIR}" ]]; then
  echo "==> Installing infra repo to ${INFRA_DIR}"
  mkdir -p "${INFRA_DIR}"
  rsync -a --delete "${SCRIPT_DIR}/" "${INFRA_DIR}/"
  # Re-source .env from install location
  set -a
  source "${INFRA_DIR}/.env"
  set +a
  export SCRIPT_DIR="${INFRA_DIR}"
fi

echo "========================================"
echo " Infrastructure Stack Setup"
echo "========================================"
echo ""

# --- Run modules in order ---
MODULES=(
  "01-system-deps.sh"
  "02-timescaledb.sh"
  "03-grafana.sh"
  "04-monitoring.sh"
  "05-dashboards.sh"
  "06-hardening.sh"
)

for module in "${MODULES[@]}"; do
  script="${SCRIPT_DIR}/scripts/${module}"
  if [[ ! -f "${script}" ]]; then
    echo "ERROR: Module not found: ${script}"
    exit 1
  fi
  echo ""
  echo "========================================"
  echo " Running: ${module}"
  echo "========================================"
  echo ""
  bash "${script}"
done

# --- Final summary ---
echo ""
echo "========================================"
echo " Setup Complete — Service Summary"
echo "========================================"
echo ""

# Collect statuses
services=("postgresql" "grafana-server" "prometheus" "node_exporter" "fail2ban" "ufw")
all_ok=true

for svc in "${services[@]}"; do
  if systemctl is-active --quiet "${svc}" 2>/dev/null; then
    status="RUNNING"
  else
    status="NOT RUNNING"
    all_ok=false
  fi
  printf "  %-20s %s\n" "${svc}" "${status}"
done

echo ""
echo "Access URLs:"
echo "  Grafana:        http://<server-ip>:${GRAFANA_PORT}"
echo "  Prometheus:     http://localhost:${PROMETHEUS_PORT}  (localhost only)"
echo "  Node Exporter:  http://localhost:${NODE_EXPORTER_PORT}  (localhost only)"
echo "  TimescaleDB:    localhost:${PG_PORT}  (localhost only)"
echo ""
echo "Config:           ${INFRA_DIR}/.env"
echo "Dashboards:       ${INFRA_DIR}/grafana/dashboards/"
echo "Skill reference:  ${INFRA_DIR}/skills/infrastructure.md"
echo ""

if $all_ok; then
  echo "All services are running."
else
  echo "WARNING: Some services are not running. Check logs with: journalctl -u <service>"
fi
