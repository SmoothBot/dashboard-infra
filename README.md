# Infrastructure Stack

Production-ready analytics stack for bare metal Ubuntu servers. Provisions TimescaleDB, Grafana, Prometheus, and node_exporter with full security hardening — all from a single idempotent entrypoint.

## What's Included

- **TimescaleDB** — PostgreSQL with time-series extensions, memory-tuned config, scoped service account
- **Grafana OSS** — Auto-provisioned datasource and dashboards, admin password from config
- **Prometheus** — System and database metrics collection with 30-day retention
- **node_exporter** — Hardware and OS metrics for Prometheus
- **Security hardening** — UFW firewall, SSH lockdown (key-only, no root), fail2ban, sysctl kernel params
- **Two dashboards** — System Health (CPU, memory, disk, network) and Database Health (connections, cache, bloat, replication)

## Prerequisites

- Ubuntu 22.04+ (24.04 compatible)
- Root or sudo access
- SSH key already configured for your user (password auth will be disabled)
- Internet access (to fetch packages from upstream repos)

## Quick Start

```bash
# Clone the repo
git clone <repo-url> /tmp/infra
cd /tmp/infra

# Configure
cp .env.example .env
nano .env  # Set passwords, ports, etc.

# Run
sudo ./setup.sh
```

The setup installs itself to `/opt/infra/` for stable paths, then runs all modules in order.

## Configuration

All passwords, ports, and tunables are in `.env`. Copy `.env.example` and edit:

| Variable | Description | Default |
|----------|-------------|---------|
| `PG_DB_NAME` | Analytics database name | `analytics` |
| `PG_DB_USER` | Database service account | `analytics_svc` |
| `PG_DB_PASSWORD` | Database password | (must change) |
| `PG_PORT` | PostgreSQL port | `5432` |
| `GRAFANA_ADMIN_USER` | Grafana admin username | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | (must change) |
| `GRAFANA_PORT` | Grafana HTTP port | `3000` |
| `PROMETHEUS_PORT` | Prometheus port (localhost only) | `9090` |
| `PROMETHEUS_RETENTION` | Prometheus data retention | `30d` |
| `NODE_EXPORTER_PORT` | node_exporter port (localhost only) | `9100` |
| `SSH_PORT` | SSH listen port | `22` |
| `INFRA_DIR` | Install directory | `/opt/infra` |

## Re-running on an Existing Machine

The entire stack is idempotent. Running `sudo ./setup.sh` again will:

- Reinstall/upgrade packages without data loss
- Overwrite config files with current settings from `.env`
- Recreate database roles and permissions (no data deletion)
- Reapply firewall rules and hardening
- Redeploy dashboards

You can also re-run individual modules:

```bash
sudo bash /opt/infra/scripts/02-timescaledb.sh   # Just reconfigure DB
sudo bash /opt/infra/scripts/06-hardening.sh      # Just reapply hardening
```

Make sure `.env` is sourced in your environment before running individual scripts, or run them through `setup.sh`.

## Adding Dashboards

1. Create a Grafana dashboard JSON file ([JSON model reference](https://grafana.com/docs/grafana/latest/dashboards/json-model/))
2. Drop the file into `/opt/infra/grafana/dashboards/`
3. Grafana picks up changes automatically within 30 seconds

Or force a reload:

```bash
sudo systemctl restart grafana-server
```

Alternatively, re-run the dashboard script:

```bash
sudo bash /opt/infra/scripts/05-dashboards.sh
```

## Project Structure

```
infra/
├── setup.sh                  # Single entrypoint
├── scripts/
│   ├── 01-system-deps.sh     # Base packages and APT repos
│   ├── 02-timescaledb.sh     # PostgreSQL + TimescaleDB
│   ├── 03-grafana.sh         # Grafana install and provisioning
│   ├── 04-monitoring.sh      # node_exporter + Prometheus
│   ├── 05-dashboards.sh      # Deploy dashboard JSON files
│   └── 06-hardening.sh       # Firewall, SSH, fail2ban, sysctl
├── config/
│   ├── postgresql.conf.tmpl  # Memory-aware PostgreSQL config template
│   ├── pg_hba.conf           # PostgreSQL access control
│   ├── prometheus.yml        # Prometheus scrape targets
│   └── sysctl-hardening.conf # Kernel security parameters
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/
│   │   │   └── timescaledb.yml
│   │   └── dashboards/
│   │       └── dashboard-provider.yml
│   └── dashboards/
│       ├── system-health.json
│       └── database-health.json
├── skills/
│   └── infrastructure.md     # Claude Code skill reference
├── .env.example
└── README.md
```

## Claude Code Skill

Other projects on this machine can reference the infrastructure skill in their `CLAUDE.md`:

```markdown
## Skills
- Read `/opt/infra/skills/infrastructure.md` for available database, monitoring, and dashboard infrastructure on this machine.
```

This gives Claude Code immediate context about available services, connection strings, file paths, and how to extend the stack — without needing to explore the system.

## Network Layout

| Port | Exposed | Purpose |
|------|---------|---------|
| SSH port (from .env) | External | SSH access |
| 3000 | External | Grafana |
| 5432 | Localhost only | PostgreSQL/TimescaleDB |
| 9090 | Localhost only | Prometheus |
| 9100 | Localhost only | node_exporter |

All inbound traffic is denied by default except SSH and Grafana.
