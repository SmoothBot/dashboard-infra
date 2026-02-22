#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 01 — System Dependencies & Base Packages
# =============================================================================

echo "[01] Installing base system packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  wget \
  gettext-base \
  rsync \
  ufw \
  fail2ban \
  unattended-upgrades \
  logrotate \
  jq \
  net-tools

# --- Add PostgreSQL official repo ---
echo "[01] Adding PostgreSQL APT repository..."
PG_REPO_FILE="/etc/apt/sources.list.d/pgdg.list"
if [[ ! -f "${PG_REPO_FILE}" ]]; then
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] \
    https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > "${PG_REPO_FILE}"
fi

# --- Add TimescaleDB repo ---
echo "[01] Adding TimescaleDB APT repository..."
TSDB_REPO_FILE="/etc/apt/sources.list.d/timescaledb.list"
if [[ ! -f "${TSDB_REPO_FILE}" ]]; then
  curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/timescaledb-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/timescaledb-archive-keyring.gpg] \
    https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -cs) main" \
    > "${TSDB_REPO_FILE}"
fi

# --- Add Grafana repo ---
echo "[01] Adding Grafana APT repository..."
GRAFANA_REPO_FILE="/etc/apt/sources.list.d/grafana.list"
if [[ ! -f "${GRAFANA_REPO_FILE}" ]]; then
  curl -fsSL https://apt.grafana.com/gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/grafana-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/grafana-archive-keyring.gpg] \
    https://apt.grafana.com stable main" \
    > "${GRAFANA_REPO_FILE}"
fi

# --- Refresh with new repos ---
apt-get update -qq

echo "[01] System dependencies installed."
