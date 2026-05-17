# Adding Kopia Backup to a Service

## Quick start (3 files)

### 1. `defaults/backup.yml` — declare sources and retention

```yaml
# Identity on the Kopia server
kopia_override_username: <service_name>
kopia_override_hostname: server

# Per-source paths + retention (override global defaults selectively)
kopia_sources:
  "<path_to_backup>":
    retention:
      keep_latest: 10   # omit to inherit from global policy
      keep_daily: 7
      keep_monthly: 24

# Optional — before/after snapshot-root action (inherited by all sources)
# kopia_before_snapshot_root_action_path: "templates/<svc>_before-snapshot-root.sh.j2"
```

### 2. `tasks/backup.yml` — include registration

```yaml
---
- name: Include Kopia backup defaults
  ansible.builtin.include_vars: "{{ role_path }}/defaults/backup.yml"

- name: Register Kopia backup source
  ansible.builtin.include_role:
    name: kopia_agent
    tasks_from: register_source
```

### 3. `tasks/main.yml` — include after deployment

Add after the service's deploy block:

```yaml
- ansible.builtin.include_tasks: backup.yml
```

## Reference

### Source structure

Each key in `kopia_sources` is a directory path that kopia snapshots. Retention settings are per-source — omit any `keep_*` to inherit from global policy (set by kopia_server role). Folder-level actions can be added per source.

```yaml
kopia_sources:
  "/srv/docker_data/my-service":          # simple file backup
    retention:
      keep_latest: 10
      keep_daily: 30
  "/opt/ansible/my-service/backups":      # dump/dir output from pre-action script
    retention:
      keep_latest: 5
      keep_monthly: 12
  "/srv/docker_data/archive-store":       # folder actions for dedup optimization
    retention:
      keep_daily: 30
    before_folder_action_path: "templates/unarchive.sh.j2"
    after_folder_action_path: "templates/rearchive.sh.j2"
```

### Action types

| Type | Scope | Inherited? | Defined where |
|------|-------|------------|---------------|
| `before-snapshot-root` | Once per snapshot | Yes (→ all sources) | Identity level (`kopia_before_snapshot_root_action_path`) |
| `after-snapshot-root` | Once per snapshot | Yes (→ all sources) | Identity level (`kopia_after_snapshot_root_action_path`) |
| `before-folder` | Per directory | **No** | Per-source (`before_folder_action_path` inside source entry) |
| `after-folder` | Per directory | **No** | Per-source (`after_folder_action_path` inside source entry) |

Snapshot-root actions are defined at the identity level and inherited by all sources. Folder actions must be set per-source path — useful for unarchiving before snapshot (dedup on individual files), then re-archiving after.

### Action script template

Jinja2 template deployed to `/opt/ansible/kopia/agents/<username>_before-snapshot-root.sh`:

```sh
#!/bin/sh
set -e

DUMP_DIR="/srv/docker_data/my-service/backups"
mkdir -p "$DUMP_DIR"

# Dump data into the source directory kopia will snapshot
cd /opt/ansible/my-service && docker compose exec -T myapp dump > "$DUMP_DIR/dump.sql"
```

Script receives these environment variables from kopia:

| Variable | Value |
|----------|-------|
| `KOPIA_ACTION` | `before-snapshot-root` or `after-snapshot-root` |
| `KOPIA_SOURCE_PATH` | Path being snapshotted |
| `KOPIA_SNAPSHOT_ID` | Unique snapshot ID |

### Secrets in actions

Never pass passwords as environment variables (kopia logs action commands). Use credential files:

- **PostgreSQL**: `.pgpass` file deployed via Ansible template (`mode: 0600`)
- **API tokens**: `EnvironmentFile=` in systemd service (loaded from `.env` if `kopia_pre_action_env` is defined)

### Timer schedule

Default: hourly with 300s random delay. Override per-service by setting `kopia_timer_on_calendar` before including register_source:

```yaml
- name: Register Kopia backup source
  ansible.builtin.include_role:
    name: kopia_agent
    tasks_from: register_source
  vars:
    kopia_override_username: myservice
    kopia_override_hostname: server
    kopia_timer_on_calendar: "daily"      # daily instead of hourly
```

## Deploy and verify

```bash
# Deploy single service (includes backup)
ansible-playbook playbooks/servers.yml --tags <service_name>

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
