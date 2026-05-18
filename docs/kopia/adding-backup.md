# Adding Kopia Backup to a Service

## Quick start (1 file + inventory entry)

All backup orchestration lives in the `kopia_agent` role, driven by inventory declarations. No service role changes needed.

### 1. Add source declaration to host_vars

Edit `inventory/host_vars/<host>.yml`:

```yaml
backup_sources:
  myservicename:
    hostname: server
    paths:
      "/srv/docker_data/my-service":
        retention:
          keep_latest: 10
          keep_daily: 30
          keep_monthly: 12
```

### 2. Add action script template (if needed)

If the service needs preparation before snapshot (database dump, cache flush, etc.), create a template in `kopia_agent/templates/actions/<service>/`:

```bash
mkdir -p playbooks/roles/infra/kopia_agent/templates/actions/myservicename/
```

Create `playbooks/roles/infra/kopia_agent/templates/actions/myservicename/before-snapshot-root.sh.j2`:

```sh
#!/bin/sh
set -e

# Script runs before each snapshot. Ansible vars available through normal precedence.
DUMP_DIR="/srv/docker_data/my-service/backups"
mkdir -p "$DUMP_DIR"
cd /opt/ansible/my-service && docker compose exec -T myapp dump > "$DUMP_DIR/dump.sql"
```

**Redirect snapshot target (optional):** Print `KOPIA_SNAPSHOT_PATH=<dir>` to stdout to tell kopia to snapshot a different directory instead of the original source. Useful for staging or PIT dumps:

```sh
echo "KOPIA_SNAPSHOT_PATH=$DUMP_DIR"
```

Then enable the action in inventory:

```yaml
backup_sources:
  myservicename:
    hostname: server
    paths:
      "/srv/docker_data/my-service": {}
    actions:
      before-snapshot-root: true   # → templates/actions/myservicename/before-snapshot-root.sh.j2
```

### 3. Re-run kopia roles

```bash
ansible-playbook playbooks/servers.yml --tags kopia_server,kopia_agent --limit <host>
```

The `kopia_agent` meta dependency on `kopia_server` ensures server runs first. The agent role iterates over `backup_sources` and registers everything automatically: provisions user, connects agent, deploys action scripts, sets retention, seeds first snapshot, starts systemd timer. No service role changes needed.

---

## Reference

### Inventory schema

```yaml
backup_sources:
  <service_name>:          # Kopia override_username (identity)
    hostname: server       # Kopia override_hostname suffix
    paths:                 # Dict of path → config
      "/path/to/backup":
        retention:         # Optional — omit to use global Kopia policy
          keep_latest: 10
          keep_daily: 30
        before-folder: true   # Folder action (per-path, NOT inherited)
        after-folder: true    # → templates/actions/<service>/after-folder.sh.j2
    actions:               # Snapshot-root actions (inherited by all paths)
      before-snapshot-root: true
      # after-snapshot-root: true
    enabled: true          # Optional — set to false to pause timer without losing config
    schedule: "hourly"     # Optional — systemd OnCalendar expression
```

### Action types and resolution

| Type | Scope | Inherited? | Template resolved to |
|------|-------|------------|---------------------|
| `before-snapshot-root` | Once per snapshot | Yes (→ all paths) | `actions/<service>/before-snapshot-root.sh.j2` |
| `after-snapshot-root` | Once per snapshot | Yes (→ all paths) | `actions/<service>/after-snapshot-root.sh.j2` |
| `before-folder` | Per directory | **No** | `actions/<service>/before-folder.sh.j2` |
| `after-folder` | Per directory | **No** | `actions/<service>/after-folder.sh.j2` |

Snapshot-root actions are set once and inherited by all paths under the identity. Folder actions must be declared per-path inside the `paths` dict — Kopia does not inherit them from parent directories.

### Retention hierarchy

1. **Per-path** — `paths.<path>.retention.*` (most specific)
2. **Global Kopia server policy** — `kopia_global_retention` in `group_vars/servers.yml` (fallback)

Omit per-path retention entirely to use global policy:

```yaml
backup_sources:
  step_ca:
    hostname: server
    paths:
      "{{ step_ca_data_dir }}/certs": {}   # no retention → inherits from global policy
```

### Pausing a backup (enabled flag)

Set `enabled: false` at source level to stop the timer:

```yaml
backup_sources:
  postgres:
    hostname: server
    enabled: false   # ← timer stopped for all paths under this identity
    paths:
      "{{ postgres_data_dir }}/backups":
        retention:
          keep_latest: 10
```

Or at path level to disable individual directories (timer still runs, but skips disabled paths):

```yaml
backup_sources:
  archive-store:
    hostname: server
    paths:
      "/srv/docker_data/archive-store":
        retention:
          keep_daily: 30
      "/mnt/temp/staging-data":
        enabled: false   # ← this path skipped, timer still runs for other paths
```

Re-run with `--tags kopia_server,kopia_agent` — disabled paths are skipped (no policy set, no actions deployed, no snapshots). Flip back to `true` (or remove key) to resume. All Kopia config and existing snapshots remain intact.

### Timer schedule

Default: `hourly` with 300s random delay. Override per-service via `schedule`:

```yaml
backup_sources:
  vaultwarden:
    hostname: server
    paths:
      "/srv/docker_data/vaultwarden": {}
    schedule: "daily"   # daily instead of hourly
```

### Secrets in actions

Never pass passwords as environment variables (kopia logs action commands). Use credential files:

- **PostgreSQL**: `.pgpass` file deployed via Ansible template (`mode: 0600`)
- **API tokens**: `EnvironmentFile=` in systemd service (loaded from `.env` if `pre_action_env` is defined)

### Environment variables passed by Kopia

Action scripts receive these variables at runtime:

| Variable | Value |
|----------|-------|
| `KOPIA_ACTION` | `before-folder`, `after-folder`, `before-snapshot-root`, or `after-snapshot-root` |
| `KOPIA_SOURCE_PATH` | Path being snapshotted |
| `KOPIA_SNAPSHOT_ID` | Unique snapshot ID (64-bit number) |

---

## Deploy and verify

```bash
# Run kopia roles for a specific host
ansible-playbook playbooks/servers.yml --tags kopia_server,kopia_agent --limit lab1

# Verify snapshots on the host
ssh lab1 "kopia snapshot list --config-file /opt/ansible/kopia/agents/<username>.config"

# Check timer status
ssh lab1 "systemctl status kopia-backup@<username>.timer"

# Test full chain manually
ssh lab1 "systemctl start kopia-backup@<username>.service && journalctl -u kopia-backup@<username>.service --no-pager"
```

## Rollback

```bash
# Disable timer, remove config (on host)
ssh lab1 "systemctl disable --now kopia-backup@<username>.timer && rm /opt/ansible/kopia/agents/<username>.config"

# Remove server-side user (optional)
ssh lab1 "cd /opt/ansible/kopia_server && docker compose exec kopia-server kopia server users delete <username>@server"
```
