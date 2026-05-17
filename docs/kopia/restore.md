# Kopia Restore Guide

## Quick reference

```bash
# List snapshots for a service identity
ssh lab1 "kopia snapshot list --config-file /opt/ansible/kopia/agents/<username>.config"

# Show contents of a specific snapshot
ssh lab1 "kopia show <snapshot-id> --config-file /opt/ansible/kopia/agents/<username>.config"
```

## Standard file restore (any service)

Restore individual files or directories from a snapshot to a local path:

```bash
SSH into the host (e.g. lab1):
ssh lab1

# 1. Find the snapshot you want
kopia snapshot list --config-file /opt/ansible/kopia/agents/<username>.config

# 2. Restore specific file/directory from snapshot to target path
kopia restore <snapshot-id> \
  --file-path=relative/path/in/snapshot \
  --destination=/tmp/restore-target \
  --config-file /opt/ansible/kopia/agents/<username>.config
```

The `--file-path` is optional — omit it to restore the entire snapshot tree.

### Restore over SSH (remote host)

If restoring from a different machine, use `kopia repository connect server` with the service identity first:

```bash
# Connect as the service identity (one-time setup on target host)
kopia repository connect server \
  --url=https://lab1.lan:443 \
  --password='<repo-password>' \
  --override-username=<username> \
  --override-hostname=server

# Then restore as normal
kopia restore <snapshot-id> --destination=/tmp/restore-target
```

## PostgreSQL restore (logical dump)

PostgreSQL backups are per-database `.sql` dumps plus a globals file — not raw data directories. Restore requires a running PostgreSQL instance.

### Snapshot contents

```
dump-globals.sql        # roles, tablespaces
dump-postgres.sql       # postgres database
dump-myapp.sql          # your personal database
dump-vaultwarden.sql    # service database
...
```

### Restore all databases (full recovery)

```bash
ssh lab1

# 1. Find the snapshot with the dumps you want
kopia snapshot list --config-file /opt/ansible/kopia/agents/postgres.config

# 2. Restore entire backups directory to a temporary location
kopia restore <snapshot-id> \
  --destination=/tmp/pg-restore \
  --config-file /opt/ansible/kopia/agents/postgres.config

# 3. Stop the running PostgreSQL container
cd /opt/ansible/postgres && docker compose stop postgres

# 4. Import globals first (roles, tablespaces)
cat /tmp/pg-restore/dump-globals.sql | docker compose exec -T -i postgres psql -U postgres

# 5. Drop and recreate each database from its dump
for f in /tmp/pg-restore/dump-*.sql; do
  dbname=$(basename "$f" .sql | sed 's/^dump-//')
  docker compose exec -T postgres dropdb --if-exists --force "$dbname" -U postgres || true
  docker compose exec -T postgres createdb -U postgres "$dbname"
done

for f in /tmp/pg-restore/dump-*.sql; do
  dbname=$(basename "$f" .sql | sed 's/^dump-//')
  cat "$f" | docker compose exec -T -i postgres psql -U postgres -d "$dbname"
done

# 6. Restart PostgreSQL
cd /opt/ansible/postgres && docker compose start postgres

# 7. Clean up temporary files
rm -rf /tmp/pg-restore
```

### Restore a single database

```bash
ssh lab1

# 1. Find snapshot and restore just the file you need
kopia restore <snapshot-id> \
  --file-path=dump-myapp.sql \
  --destination=/tmp/pg-restore \
  --config-file /opt/ansible/kopia/agents/postgres.config

# 2. Drop and recreate the target database
cd /opt/ansible/postgres
docker compose exec -T postgres dropdb --if-exists --force myapp -U postgres || true
docker compose exec -T postgres createdb -U postgres myapp

# 3. Import the dump
cat /tmp/pg-restore/dump-myapp.sql | docker compose exec -T -i postgres psql -U postgres -d myapp

rm -rf /tmp/pg-restore
```

### Restore to a new instance (different host/port)

If the original database is still running and you can't stop it:

```bash
cd /opt/ansible/postgres && cp docker-compose.yml docker-compose.restore.yml
# Edit restore file: change port mapping to e.g. 5433:5432, rename service/container

docker compose -f docker-compose.restore.yml up -d

# Import globals + all databases into new instance
cat /tmp/pg-restore/dump-globals.sql | docker compose -f docker-compose.restore.yml exec -T -i postgres psql -U postgres

for f in /tmp/pg-restore/dump-*.sql; do
  dbname=$(basename "$f" .sql | sed 's/^dump-//')
  docker compose -f docker-compose.restore.yml exec -T postgres createdb -U postgres "$dbname"
done

for f in /tmp/pg-restore/dump-*.sql; do
  cat "$f" | docker compose -f docker-compose.restore.yml exec -T -i postgres psql -U postgres
done
```


## Vaultwarden restore (planned)

When implemented, vaultwarden backup will include both data directory and API export. Restore procedure depends on format:

- **Data dir**: Stop container, restore files to `/srv/docker_data/vaultwarden`, restart
- **API export**: Import via `curl` to running instance's admin endpoint (preserves all users/orgs)

## Emergency recovery (host completely dead)

### Scenario: lab1 is destroyed, need to recover from Kopia server on lab2

```bash
# 1. Boot target machine with LiveCD or minimal Ubuntu install

# 2. Install Kopia binary manually
wget https://github.com/kopia/kopia/releases/download/v<version>/kopia_<version>_linux_amd64.deb
dpkg -i kopia_*.deb

# 3. Connect to repository server as the service identity
kopia repository connect server \
  --url=https://lab2.lan:443 \
  --password='<repo-password>' \
  --override-username=<username> \
  --override-hostname=server

# 4. Restore data (no local cache — may be slow on first run)
kopia restore <snapshot-id> --destination=/target/path

# 5. Re-deploy service via Ansible once base system is recovered
```

### No-cache restore flag

If the host has no Kopia metadata cache, use `--no-cache` to bypass local index download (slower but works):

```bash
kopia repository connect server \
  --url=https://lab2.lan:443 \
  --password='<repo-password>' \
  --override-username=<username> \
  --override-hostname=server \
  --no-cache

kopia restore <snapshot-id> --destination=/target/path
```

## Admin token (browse all identities)

The admin token (`vault_kopia_admin_token`) can browse any identity's snapshots without connecting as that specific user:

```bash
# Connect with admin token
kopia repository connect server \
  --url=https://lab1.lan:443 \
  --admin-token='<admin-token-from-vault>'

# List all snapshots across all identities
kopia snapshot list

# Restore from any identity's snapshot
kopia restore <snapshot-id> --destination=/tmp/restore-target
```

Useful for cross-service recovery or when service-specific credentials are lost.
