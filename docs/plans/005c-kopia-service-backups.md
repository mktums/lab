> **⚠️ Superseded by [011](./011-centralize-kopia-backups.md).**
> The per-service `defaults/backup.yml` + `tasks/backup.yml` pattern described here
> has been replaced with inventory-driven declarations in host_vars. Backup orchestration
> now lives entirely in the kopia_agent role — see [adding-backup.md](../kopia/adding-backup.md).

# 005c: Kopia service backups (postgres, vaultwarden, linkwarden)

## Motivation

Integrate backup registration into selected service roles using the kopia_agent role from [005b](./005b-kopia-agents.md). Each service declares its backup sources and retention policy in `defaults/backup.yml` and includes `register_source.yml` after deployment.

### Scope

| Service | Status | Backup target | Pre-action needed? |
|---------|--------|---------------|-------------------|
| postgres | Done | Logical dump via pg_dump to `backups/` dir | before-snapshot-root: dumps DB once per snapshot |
| step_ca | Done | `/srv/docker_data/step-ca/certs`, `/srv/docker_data/step-ca/secrets` | No — static files |
| vaultwarden | Done | Staging dir (config.json, attachments/, sends/) via KOPIA_SNAPSHOT_PATH redirect | before-snapshot-root: copies with `cp -a`, after-snapshot-root: cleans staging |
| linkwarden | Done | Archives dir (`/data/data`) — DB covered by postgres pg_dumpall | No pre-action needed (static files) |

## Integration pattern

### 1. `defaults/backup.yml` — declare sources and retention

```yaml
# Kopia identity (override_username @ override_hostname)
kopia_override_username: <service_name>
kopia_override_hostname: server

# Per-source paths + retention
kopia_sources:
  "<path_to_backup>":
    retention:
      keep_latest: 10       # omit any to inherit from global policy
      keep_daily: 7
      keep_monthly: 24

# Optional — snapshot-root action (inherited by all sources)
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

### 3. `tasks/main.yml` — include after deployment block

```yaml
- ansible.builtin.include_tasks: backup.yml
```

## PostgreSQL (done)

**defaults/backup.yml:**
```yaml
kopia_override_username: postgres
kopia_override_hostname: server

kopia_sources:
  "{{ postgres_data_dir }}/backups":
    retention:
      keep_latest: 10
      keep_hourly: 48
      keep_daily: 7
      keep_weekly: 4
      keep_monthly: 24
      keep_annual: 3

kopia_before_snapshot_root_action_path: "templates/postgres_before-snapshot-root.sh.j2"
```

**templates/postgres_before-snapshot-root.sh.j2:**
```sh
#!/bin/sh
set -e

DUMP_DIR="{{ postgres_data_dir }}/backups"
COMPOSE_DIR={{ postgres_opt_dir }}
PG_USER={{ postgres_user | default('postgres') }}

mkdir -p "$DUMP_DIR"
cd "$COMPOSE_DIR"

# Global objects (roles, tablespaces)
docker compose exec -T postgres pg_dumpall -U "$PG_USER" -g > "$DUMP_DIR/dump-globals.sql"

# Per-database dumps
db_list=$(docker compose exec -T postgres psql -U "$PG_USER" -t -c "SELECT datname FROM pg_database WHERE datistemplate = false")
for db in $db_list; do
  docker compose exec -T postgres pg_dump -U "$PG_USER" "$db" > "$DUMP_DIR/dump-${db}.sql"
done
```

**Backup chain:**
1. Timer `kopia-backup@postgres.timer` fires (hourly + random delay)
2. Service runs: `/usr/bin/kopia snapshot create --all --config /opt/ansible/kopia/agents/postgres.config`
3. Kopia finds before-snapshot-root action, dumps globals + per-DB into `backups/` dir
4. Kopia snapshots all `.sql` files (dedup uploads only changed DBs, retention applies)
5. Process exits, systemd marks unit as inactive

**Key design:** Source path points to the `backups/` subdirectory, not the live postgres data dir. The action dumps DB into that directory before kopia scans it. Dedup ensures one copy of identical dumps; retention gives restore points.

## Deployment

Run backup configuration across all services:
```
ansible-playbook playbooks/servers.yml --tags kopia
```

Or deploy single service (includes backup):
```
ansible-playbook playbooks/servers.yml --tags postgres
```

## Rollback

Disable systemd timer, remove agent config file. Server-side user cleaned via `docker compose exec kopia-server kopia server users delete <identity>`. Existing snapshots expire per retention policy.
