#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 06 — Security Hardening (UFW, SSH, fail2ban, sysctl)
# =============================================================================

echo "[06] Applying security hardening..."

# ---- UFW Firewall ----
echo "[06] Configuring UFW..."

# Reset to clean state
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (custom port from .env)
ufw allow "${SSH_PORT}/tcp" comment "SSH"

# Allow Grafana
ufw allow "${GRAFANA_PORT}/tcp" comment "Grafana"

# PostgreSQL, Prometheus, node_exporter are localhost-only — no UFW rule needed
# (they bind to 127.0.0.1 in their configs)

# Enable firewall
ufw --force enable

echo "[06] UFW rules:"
ufw status verbose

# ---- SSH Hardening ----
echo "[06] Hardening SSH..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# Backup original if not already backed up
if [[ ! -f "${SSHD_CONFIG}.orig" ]]; then
  cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.orig"
fi

# Apply hardening settings (idempotent — overwrites values if present, appends if not)
declare -A SSH_SETTINGS=(
  ["Port"]="${SSH_PORT}"
  ["PermitRootLogin"]="no"
  ["PasswordAuthentication"]="no"
  ["ChallengeResponseAuthentication"]="no"
  ["MaxAuthTries"]="3"
  ["MaxSessions"]="5"
  ["X11Forwarding"]="no"
  ["AllowAgentForwarding"]="no"
  ["AllowTcpForwarding"]="no"
  ["PermitEmptyPasswords"]="no"
  ["ClientAliveInterval"]="300"
  ["ClientAliveCountMax"]="2"
  ["LoginGraceTime"]="30"
  ["Protocol"]="2"
)

for key in "${!SSH_SETTINGS[@]}"; do
  value="${SSH_SETTINGS[$key]}"
  if grep -qE "^\s*#?\s*${key}\s" "${SSHD_CONFIG}"; then
    sed -i "s|^\s*#*\s*${key}\s.*|${key} ${value}|" "${SSHD_CONFIG}"
  else
    echo "${key} ${value}" >> "${SSHD_CONFIG}"
  fi
done

# Validate sshd config before restarting
if sshd -t 2>/dev/null; then
  systemctl restart sshd
  echo "[06] SSH hardened and restarted."
else
  echo "[06] WARNING: sshd config validation failed. Restoring backup."
  cp "${SSHD_CONFIG}.orig" "${SSHD_CONFIG}"
  systemctl restart sshd
fi

# ---- fail2ban ----
echo "[06] Configuring fail2ban..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
maxretry = 3
bantime = 7200
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "[06] fail2ban configured for SSH on port ${SSH_PORT}."

# ---- sysctl hardening ----
echo "[06] Deploying sysctl hardening config..."

cp "${SCRIPT_DIR}/config/sysctl-hardening.conf" /etc/sysctl.d/99-hardening.conf
sysctl --system > /dev/null 2>&1

echo "[06] sysctl hardening applied."

# ---- Verify services run as non-root ----
echo "[06] Verifying non-root service users..."

check_user() {
  local svc="$1"
  local expected="$2"
  local actual
  actual=$(ps -eo user,comm | grep "$svc" | head -1 | awk '{print $1}' || true)
  if [[ -n "$actual" && "$actual" != "root" ]]; then
    echo "  ${svc}: running as ${actual}"
  elif [[ -z "$actual" ]]; then
    echo "  ${svc}: not currently running (will run as ${expected})"
  else
    echo "  ${svc}: WARNING — running as root"
  fi
}

check_user "prometheus" "prometheus"
check_user "node_export" "node_exporter"
check_user "postgres" "postgres"
check_user "grafana" "grafana"

# ---- Status checks ----
echo ""
if systemctl is-active --quiet ufw; then
  echo "[06] UFW is ACTIVE."
else
  echo "[06] WARNING: UFW is not active."
fi

if systemctl is-active --quiet fail2ban; then
  echo "[06] fail2ban is RUNNING."
else
  echo "[06] WARNING: fail2ban is not running."
fi

echo "[06] Hardening complete."
