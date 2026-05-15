# 005a: Deploy Kopia repository server

## Motivation

Deploy centralized backup infrastructure using [Kopia](https://kopia.io/) — a fast, encrypted, deduplicated backup tool with CLI clients and Android app support. This part covers the repository server deployment only. Agent deployment is covered in [005b](./005b-kopia-agents.md).

### Scope

| Component | Role |
|-----------|------|
| Backup server | Kopia repository on lab1 (primary) or lab2 (fallback) |

## Affected files

| File | Change |
|------|--------|
| `playbooks/roles/kopia_server/` | New — repository server role |
| `inventory/group_vars/servers.yml` | Kopia server vars (repo path, credentials) |
| `inventory/hosts.yml` | Add `kopia_server_hosts` group |
| `vault/secrets.yml` | Server admin credentials, repo encryption key |

## Architecture

Single Docker container running `kopia server start` on the designated lab host. The server exposes port 51514 (internal) with TLS and admin/control credentials from vault.

### Storage backend

Local disk on lab1 (2x3TB WD Reds in mirror). No external cloud storage yet. Off-site replication via USB rotation (Samsung T7 Shield 2TB) or `kopia repository sync-to` to a separate local disk.

### Multi-user support

Kopia server supports multi-tenant access with ACL-based isolation per user@hostname identity. Each agent connects as a distinct user account provisioned via `kopia server user add`. Default ACL rules grant authenticated users read/write access to their own policies and snapshots, plus append access to the repository.

### Maintenance

Kopia v0.6+ runs automatic maintenance when any connected client executes CLI commands (our systemd timers trigger `snapshot create` which activates the cycle):
- **Quick maintenance** (~hourly) — keeps q/n blob counts low, enabled by default
- **Full maintenance** (every 24 hours) — snapshot GC and compaction, enabled by default

One `user@hostname` is designated as exclusive Maintenance Owner (`kopia maintenance set --owner=...`). Other users skip auto-maintenance. Ansible sets this during server deployment via `delegate_to` on the kopia_server host.

### Repository verification

Two tiers run on the **server host** under admin credentials (not from client configs — clients lack ACL scope):

1. **Metadata verify** (`kopia snapshot verify`) — runs automatically during daily full maintenance, checks index consistency and blob existence without downloading files
2. **Bit rot check (daily)** (`kopia snapshot verify --verify-files-percent=5`) — daily systemd timer `kopia-verify.timer`, ~350GB/week on 1TB repo, full coverage in ~2 weeks
3. **Full audit (monthly)** (`kopia snapshot verify --verify-files-percent=100`) — monthly systemd timer `kopia-verify-full.timer`, single predictable window

Verification uses the admin repository connection (full access to all snapshots across users), not individual agent identities.

## Implementation steps

### Step 1: Deploy Kopia repository server role

- Create dedicated Docker container on lab1 host
- Initialize encrypted repository on local storage (mirror array)
- Configure TLS certificate generation
- Set admin credentials from vault (.env file, mode 0600)
- Deploy via `playbooks/roles/kopia_server/tasks/main.yml`

### Step 2: Set maintenance ownership

- Designate first agent identity (e.g. `stepca@server`) or admin user as Maintenance Owner
- Run `kopia maintenance set --owner=<user@hostname>` via delegate_to after initial deployment
- Verify with `kopia maintenance info`

### Step 3: Deploy verification timers

- `kopia-verify.timer` (daily, randomized delay) — triggers `kopia snapshot verify --verify-files-percent=5` (~350GB/week on 1TB repo)
- `kopia-verify-full.timer` (monthly, randomized delay) — triggers `kopia snapshot verify --verify-files-percent=100`
- Both exec into running container under admin credentials

### Step 3b: Set global repository policy

| Setting | Kopia default | Value | Flag | Reasoning |
|---------|---------------|-------|------|----------|
| Compression | `none` | `zstd` | `--compression=zstd` | Best ratio/speed balance; ~60% of s2 size at 324MB/s, not CPU-bound on i7-7820X |
| Never-compress extensions | empty | `mp4,mkv,avi,iso,zip,gz,xz,tar.gz,7z,rar` | `--add-never-compress=...` | Already compressed formats; saves CPU cycles |
| Ignore cache dirs | `false` | `true` | `--ignore-cache-dirs=true` | Skips `.cache`, `Thumbs.db`, etc. automatically — reduces noise |
| Max parallel file reads | CPU cores (12) | `8` | `--max-parallel-file-reads=8` | Conservative for 16GB RAM with concurrent backups |
| Max parallel snapshots | `2` | `4` | `--max-parallel-snapshots=4` | Enough for staggered service backups without saturating mirror I/O |
| Keep latest | `3` | `10` | `--keep-latest=10` | Most recent snapshots always kept (tunable) |
| Keep hourly | `24` | `48` | `--keep-hourly=48` | 2 days of hourly snapshots (tunable) |
| Keep daily | `7` | `7` | `--keep-daily=7` | 1 week of daily snapshots — Kopia default is fine (tunable) |
| Keep weekly | `4` | `4` | `--keep-weekly=4` | 1 month of weekly snapshots — Kopia default is fine (tunable) |
| Keep monthly | `12` | `24` | `--keep-monthly=24` | 2 years of monthly snapshots (tunable) |
| Keep annual | `3` | `3` | `--keep-annual=3` | 3 years of annual snapshots — Kopia default is fine (tunable) |
| Ignore identical snapshots | `false` | `true` | `--ignore-identical-snapshots=true` | Skips byte-identical backups — saves space, keeps retention history clean |

All tunables live in `playbooks/roles/services/kopia_server/defaults/main.yml`, override in `group_vars/servers.yml` if needed.

Applied via admin credentials during deployment:
```bash
kopia policy set --global \
  --compression=zstd \
  --add-never-compress=mp4,mkv,avi,iso,zip,gz,xz,tar.gz,7z,rar \
  --max-parallel-file-reads=8 \
  --max-parallel-snapshots=4 \
  --ignore-cache-dirs=true \
  --keep-latest=10 \
  --keep-hourly=48 \
  --keep-daily=7 \
  --keep-weekly=4 \
  --keep-monthly=24 \
  --keep-annual=3 \
  --ignore-identical-snapshots=true
```

Scheduling and retention are per-source (set in `register_source.yml`), not global.

### Step 4: Test server connectivity

- Verify server starts, TLS works, port 51514 is reachable from lab hosts
- Test user provisioning via CLI (`kopia server user add`)

## Rollback

Stop container, remove role and group assignment. Repository data persists on disk for future re-deployment.
