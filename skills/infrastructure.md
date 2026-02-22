# Infrastructure Skill — Analytics Stack

This machine runs a production analytics stack managed by the infra repo at `/opt/infra/`. All services run natively via systemd (no Docker). Use this document as a reference when building applications that need database access, monitoring, or dashboards on this machine.

## Available Services

| Service | Version | Listen Address | Port | systemd Unit |
|---------|---------|---------------|------|-------------|
| PostgreSQL + TimescaleDB | Latest stable | localhost + unix socket | 5432 | `postgresql` |
| Grafana OSS | Latest stable | 0.0.0.0 | 3000 | `grafana-server` |
| Prometheus | 2.53.x | 127.0.0.1 | 9090 | `prometheus` |
| node_exporter | 1.8.x | 127.0.0.1 | 9100 | `node_exporter` |

## Database Access

### Connection Strings

**Via localhost (TCP):**
```
postgresql://<user>:<password>@localhost:5432/analytics
```

**Via unix socket:**
```
postgresql://<user>:<password>@/analytics?host=/var/run/postgresql
```

The default database is `analytics` with a service account configured in `/opt/infra/.env`. Check the `PG_DB_USER` and `PG_DB_PASSWORD` variables there.

### Requesting New Databases or Roles

1. Edit `/opt/infra/.env` — add new variables for the database/role
2. Add the creation logic to `/opt/infra/scripts/02-timescaledb.sh` (follow the existing pattern)
3. Re-run: `sudo bash /opt/infra/scripts/02-timescaledb.sh`

### TimescaleDB

The `timescaledb` extension is enabled in the `analytics` database. You can create hypertables directly:

```sql
CREATE TABLE metrics (
  time TIMESTAMPTZ NOT NULL,
  device_id TEXT,
  value DOUBLE PRECISION
);
SELECT create_hypertable('metrics', 'time');
```

## How to Add Grafana Dashboards

1. Create a Grafana dashboard JSON file (see [Grafana JSON model docs](https://grafana.com/docs/grafana/latest/dashboards/json-model/))
2. Drop the JSON file into: `/opt/infra/grafana/dashboards/`
3. Grafana auto-detects new files within 30 seconds, or restart to force reload:
   ```bash
   sudo systemctl restart grafana-server
   ```

**Expected JSON format:** Standard Grafana dashboard JSON with `id: null` and a unique `uid`. The file is auto-provisioned into the "Infrastructure" folder. Example minimal structure:

```json
{
  "id": null,
  "uid": "my-dashboard",
  "title": "My Dashboard",
  "panels": [],
  "schemaVersion": 39,
  "version": 1
}
```

## How to Add Grafana Datasources

1. Create a YAML file in: `/opt/infra/grafana/provisioning/datasources/`
2. Follow the existing format in `timescaledb.yml`:

```yaml
apiVersion: 1
datasources:
  - name: MySource
    type: <type>
    access: proxy
    url: <url>
    isDefault: false
    editable: false
    jsonData:
      <type-specific config>
    secureJsonData:
      <secrets>
```

3. Restart Grafana: `sudo systemctl restart grafana-server`

## How to Add Prometheus Scrape Targets

1. Edit: `/etc/prometheus/prometheus.yml`
2. Add a new job under `scrape_configs`:

```yaml
  - job_name: 'my-app'
    static_configs:
      - targets: ['127.0.0.1:8080']
        labels:
          instance: 'my-app'
```

3. Reload Prometheus (no restart needed):
   ```bash
   curl -X POST http://127.0.0.1:9090/-/reload
   ```

   Or restart: `sudo systemctl restart prometheus`

## Credential Access

All credentials live in `/opt/infra/.env`. **Never hardcode credentials** in application code — read them from environment variables or reference the `.env` file.

Key variables:
- `PG_DB_NAME` — database name (default: `analytics`)
- `PG_DB_USER` — database service account username
- `PG_DB_PASSWORD` — database password
- `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` — Grafana admin credentials
- `PG_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT`, `NODE_EXPORTER_PORT` — service ports
- `SSH_PORT` — SSH listen port

## Network Constraints

| Port | Binding | External Access | Purpose |
|------|---------|----------------|---------|
| SSH (from .env) | 0.0.0.0 | Yes (UFW allowed) | SSH access |
| 3000 | 0.0.0.0 | Yes (UFW allowed) | Grafana web UI |
| 5432 | 127.0.0.1 | **No** | PostgreSQL/TimescaleDB |
| 9090 | 127.0.0.1 | **No** | Prometheus |
| 9100 | 127.0.0.1 | **No** | node_exporter |

### Opening a New Port

1. Edit `/opt/infra/scripts/06-hardening.sh` — add a `ufw allow` rule
2. Re-run: `sudo bash /opt/infra/scripts/06-hardening.sh`

Or manually: `sudo ufw allow <port>/tcp comment "Description"`

## File Paths

### Config Files
| File | Path |
|------|------|
| Stack config (.env) | `/opt/infra/.env` |
| PostgreSQL config | `/etc/postgresql/<ver>/main/postgresql.conf` |
| PostgreSQL HBA | `/etc/postgresql/<ver>/main/pg_hba.conf` |
| Prometheus config | `/etc/prometheus/prometheus.yml` |
| Grafana config | `/etc/grafana/grafana.ini` |
| Grafana datasources | `/etc/grafana/provisioning/datasources/` |
| Grafana dashboard provider | `/etc/grafana/provisioning/dashboards/` |
| Grafana dashboards (source) | `/opt/infra/grafana/dashboards/` |
| sysctl hardening | `/etc/sysctl.d/99-hardening.conf` |
| SSH config | `/etc/ssh/sshd_config` |
| fail2ban config | `/etc/fail2ban/jail.local` |

### Data Directories
| Service | Path |
|---------|------|
| PostgreSQL data | `/var/lib/postgresql/<ver>/main/` |
| PostgreSQL logs | `/var/lib/postgresql/<ver>/main/log/` |
| Prometheus data | `/var/lib/prometheus/` |
| Grafana data | `/var/lib/grafana/` |

### Log Locations
| Service | Command |
|---------|---------|
| PostgreSQL | `journalctl -u postgresql` or `/var/lib/postgresql/<ver>/main/log/` |
| Grafana | `journalctl -u grafana-server` |
| Prometheus | `journalctl -u prometheus` |
| node_exporter | `journalctl -u node_exporter` |
| fail2ban | `journalctl -u fail2ban` |
| SSH | `journalctl -u sshd` |

## Common Operations

```bash
# Check service status
sudo systemctl status postgresql grafana-server prometheus node_exporter

# Restart a service
sudo systemctl restart <service-name>

# View logs (last 100 lines, follow)
journalctl -u <service-name> -n 100 -f

# Check PostgreSQL connectivity
sudo -u postgres psql -c "SELECT version();"

# Connect as service account
psql -h localhost -U analytics_svc -d analytics

# Check Grafana health
curl -s http://localhost:3000/api/health | jq

# Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health}'

# Re-run full setup (idempotent)
sudo /opt/infra/setup.sh

# Re-run a single module
sudo bash /opt/infra/scripts/02-timescaledb.sh

# Check firewall status
sudo ufw status verbose

# Check fail2ban status
sudo fail2ban-client status sshd
```
