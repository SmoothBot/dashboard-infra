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

**Expected JSON format:** Standard Grafana dashboard JSON with `id: null` and a unique `uid`. Dashboards placed directly in the dashboards directory go into the "Infrastructure" folder. Reference datasources by `uid` object, not by name string. Example minimal structure:

```json
{
  "id": null,
  "uid": "my-dashboard",
  "title": "My Dashboard",
  "panels": [
    {
      "title": "Example",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "prometheus" },
      "targets": [{ "expr": "up", "refId": "A" }]
    }
  ],
  "schemaVersion": 39,
  "version": 1
}
```

**Available datasource references for dashboard JSON:**
- Prometheus: `{ "type": "prometheus", "uid": "prometheus" }`
- TimescaleDB: `{ "type": "grafana-postgresql-datasource", "uid": "timescaledb" }`

### Common pitfalls

**Pie charts with SQL datasources:** Grafana pie charts expect each **column** to be a separate slice. If your SQL returns rows like `metric | value`, the pie chart will show a single "value" entry in the legend instead of one per category. Fix this by adding a `rowsToFields` transformation to the panel:

```json
"transformations": [
  {
    "id": "rowsToFields",
    "options": {
      "mappings": [
        { "fieldName": "metric", "handlerKey": "field.name" },
        { "fieldName": "value", "handlerKey": "field.value" }
      ]
    }
  }
]
```

Your SQL should return exactly two columns: a label column (mapped to `field.name`) and a numeric column (mapped to `field.value`). The transformation pivots rows into columns so each category becomes its own field.

**Timeseries panels:** Never use the color gradient fill option (`fillOpacity` with `gradientMode: "scheme"` or `"opacity"`) on timeseries charts. It makes overlapping series unreadable and obscures the actual data. Use `"gradientMode": "none"` or a low fixed `fillOpacity` (e.g. 10) if you want subtle area shading.

## How to Create Grafana Folders

Dashboards can be organized into folders. There are two methods:

### Method 1: Subdirectories (recommended for provisioned dashboards)

Create a subdirectory under `/opt/infra/grafana/dashboards/` and enable `foldersFromFilesStructure` in the dashboard provider config at `/etc/grafana/provisioning/dashboards/dashboard-provider.yml`:

```yaml
providers:
  - name: 'default'
    orgId: 1
    folder: 'Infrastructure'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /opt/infra/grafana/dashboards
      foldersFromFilesStructure: true
```

Then organize dashboards into subdirectories — each subdirectory becomes a Grafana folder:

```
/opt/infra/grafana/dashboards/
├── trading/
│   └── pnl-overview.json        → appears in "trading" folder
├── system/
│   └── system-health.json       → appears in "system" folder
└── my-dashboard.json            → appears in "Infrastructure" (the default folder)
```

After editing the provider YAML, restart Grafana:
```bash
sudo systemctl restart grafana-server
```

**Note:** When `foldersFromFilesStructure` is `true`, the top-level `folder` field in the provider config only applies to files not inside a subdirectory. Currently this flag is `false`, so all dashboards go into "Infrastructure".

### Method 2: Grafana API (for dynamic or one-off folders)

Create a folder via the API — useful when other projects need their own folder:

```bash
# Source credentials
set -a && source /opt/infra/.env && set +a

# Create folder
curl -s -X POST "http://localhost:3000/api/folders" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"uid": "my-project", "title": "My Project"}'
```

Then move dashboards into it via the API:

```bash
# Move an existing dashboard into a folder
FOLDER_UID="my-project"
DASH_UID="my-dashboard"
# Get current dashboard model
DASH=$(curl -s "http://localhost:3000/api/dashboards/uid/${DASH_UID}" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}")
# Re-save into the folder
echo "${DASH}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
data['dashboard']['id'] = None
payload = {'dashboard': data['dashboard'], 'folderUid': '${FOLDER_UID}', 'overwrite': True}
print(json.dumps(payload))
" | curl -s -X POST "http://localhost:3000/api/dashboards/db" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" -d @-
```

### Method 3: Additional dashboard provider

For a completely separate project that manages its own dashboards, add a new provider YAML in `/etc/grafana/provisioning/dashboards/`:

```yaml
# /etc/grafana/provisioning/dashboards/my-project.yml
apiVersion: 1
providers:
  - name: 'my-project'
    orgId: 1
    folder: 'My Project'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /path/to/my-project/dashboards
      foldersFromFilesStructure: false
```

Restart Grafana after adding a new provider: `sudo systemctl restart grafana-server`

## How to Add Grafana Datasources

Datasources are managed via the Grafana HTTP API (not YAML provisioning, which has issues with password encryption in Grafana 12). Source credentials from `.env` first:

```bash
set -a && source /opt/infra/.env && set +a

curl -s -X POST "http://localhost:3000/api/datasources" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "MySource",
    "uid": "my-source",
    "type": "<plugin-type>",
    "access": "proxy",
    "url": "<url>",
    "isDefault": false,
    "jsonData": { ... },
    "secureJsonData": { "password": "..." }
  }'
```

Use a stable `uid` so dashboards can reference it reliably. Common plugin types: `prometheus`, `grafana-postgresql-datasource`, `loki`, `elasticsearch`.

To delete and recreate (idempotent update):
```bash
curl -s -X DELETE "http://localhost:3000/api/datasources/uid/my-source" \
  -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}"
# then POST to create again
```

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
