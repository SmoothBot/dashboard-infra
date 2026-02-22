#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 04 — Node Exporter & Prometheus
# =============================================================================

echo "[04] Setting up monitoring stack..."

# ---- Node Exporter ----
echo "[04] Installing node_exporter..."

NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_USER="node_exporter"

# Create dedicated user
if ! id "${NODE_EXPORTER_USER}" &>/dev/null; then
  useradd --no-create-home --shell /usr/sbin/nologin "${NODE_EXPORTER_USER}"
fi

# Download and install if not present or different version
INSTALLED_VERSION=""
if command -v node_exporter &>/dev/null; then
  INSTALLED_VERSION=$(node_exporter --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || true)
fi

if [[ "${INSTALLED_VERSION}" != "${NODE_EXPORTER_VERSION}" ]]; then
  echo "[04] Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
  cd /tmp
  curl -fsSLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
  rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
  chown "${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER}" /usr/local/bin/node_exporter
fi

# Create systemd unit
cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
ExecStart=/usr/local/bin/node_exporter \\
  --web.listen-address=127.0.0.1:${NODE_EXPORTER_PORT} \\
  --collector.systemd \\
  --collector.processes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo "[04] node_exporter started on 127.0.0.1:${NODE_EXPORTER_PORT}"

# ---- Prometheus ----
echo "[04] Installing Prometheus..."

PROMETHEUS_VERSION="2.53.3"
PROMETHEUS_USER="prometheus"

# Create dedicated user
if ! id "${PROMETHEUS_USER}" &>/dev/null; then
  useradd --no-create-home --shell /usr/sbin/nologin "${PROMETHEUS_USER}"
fi

# Create data and config directories
mkdir -p /var/lib/prometheus /etc/prometheus
chown "${PROMETHEUS_USER}:${PROMETHEUS_USER}" /var/lib/prometheus

# Download and install if not present or different version
INSTALLED_VERSION=""
if command -v prometheus &>/dev/null; then
  INSTALLED_VERSION=$(prometheus --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || true)
fi

if [[ "${INSTALLED_VERSION}" != "${PROMETHEUS_VERSION}" ]]; then
  echo "[04] Downloading Prometheus v${PROMETHEUS_VERSION}..."
  cd /tmp
  curl -fsSLO "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  tar xzf "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/
  cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /usr/local/bin/
  # Copy console templates if they exist
  if [[ -d "prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles" ]]; then
    cp -r "prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles" /etc/prometheus/
    cp -r "prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries" /etc/prometheus/
  fi
  rm -rf "prometheus-${PROMETHEUS_VERSION}.linux-amd64" "prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz"
  chown "${PROMETHEUS_USER}:${PROMETHEUS_USER}" /usr/local/bin/prometheus /usr/local/bin/promtool
fi

# Deploy prometheus.yml
echo "[04] Deploying Prometheus config..."
envsubst < "${SCRIPT_DIR}/config/prometheus.yml" > /etc/prometheus/prometheus.yml
chown "${PROMETHEUS_USER}:${PROMETHEUS_USER}" /etc/prometheus/prometheus.yml

# Create systemd unit
cat > /etc/systemd/system/prometheus.service <<EOF
[Unit]
Description=Prometheus Monitoring System
Documentation=https://prometheus.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
User=${PROMETHEUS_USER}
Group=${PROMETHEUS_USER}
Type=simple
ExecStart=/usr/local/bin/prometheus \\
  --config.file=/etc/prometheus/prometheus.yml \\
  --storage.tsdb.path=/var/lib/prometheus \\
  --storage.tsdb.retention.time=${PROMETHEUS_RETENTION} \\
  --web.listen-address=127.0.0.1:${PROMETHEUS_PORT} \\
  --web.console.templates=/etc/prometheus/consoles \\
  --web.console.libraries=/etc/prometheus/console_libraries \\
  --web.enable-lifecycle
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable prometheus
systemctl restart prometheus

# --- Wait for Prometheus ---
for i in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if systemctl is-active --quiet node_exporter; then
  echo "[04] node_exporter is RUNNING."
else
  echo "[04] ERROR: node_exporter is NOT running."
  exit 1
fi

if systemctl is-active --quiet prometheus; then
  echo "[04] Prometheus is RUNNING on 127.0.0.1:${PROMETHEUS_PORT}."
else
  echo "[04] ERROR: Prometheus is NOT running."
  exit 1
fi
